{pkgs}: {catalog-toml}: let
  lib = pkgs.lib;

  fetchHelmChart = {
    repo,
    name,
    version,
    hash,
  }:
    pkgs.stdenv.mkDerivation {
      name = "helm-chart-${name}-${version}";
      nativeBuildInputs = with pkgs; [curl yq-go cacert kubernetes-helm];
      dontUnpack = true;
      buildPhase = ''
        runHook preBuild
        if echo "${repo}" | grep -E "^https:" > /dev/null; then
          chart_url=$(\
            curl -fsSL "${repo}/index.yaml" | \
            yq '.entries."${name}"[] | select(.version == "${version}") | .urls[0]' \
          )
          if ! echo "$chart_url" | grep -E "^https:" > /dev/null; then
            chart_url="${repo}/$chart_url"
          fi
          curl -fsSL -o "$out" "$chart_url"
        elif echo "${repo}" | grep -E "^oci:"; then
          mkdir tmp
          helm pull "${repo}/${name}" --version "${version}" --destination .
          ls
          mv "${name}-${version}.tgz" $out
        else
          exit 1
        fi
        runHook postBuild
      '';
      outputHashAlgo = "sha256";
      outputHashMode = "flat";
      outputHash = hash;
    };

  catalog = builtins.fromTOML (builtins.readFile catalog-toml);
in rec {
  # Render a Helm chart into an attrset keyed by "<kind>_<metadata.name>".
  helm = {
    includeCrds ? false,
    name,
    namespace ? null,
    releaseName,
    values ? {},
  }: let
    chart = fetchHelmChart {
      inherit (catalog.chart."${name}") repo name version hash;
    };

    helmArgs =
      [
        "template"
        "-f"
        (pkgs.writers.writeJSON "values.json" values)
      ]
      ++ (lib.optionals (namespace != null) ["--namespace" namespace])
      ++ (lib.optional includeCrds "--include-crds")
      ++ [releaseName name];
  in
    builtins.fromJSON (builtins.readFile (pkgs.runCommand "helm-template" {src = chart;} ''
      mkdir chart
      tar xf "$src" -C chart
      cd chart
      ${pkgs.kubernetes-helm}/bin/helm ${lib.strings.escapeShellArgs helmArgs} | \
        ${pkgs.yq-go}/bin/yq ea 'select(. != null) as $item ireduce ({}; .[
          (
            $item.kind + "_" +
            $item.metadata.name
          )
        ] = ($item | .metadata.labels."app.kubernetes.io/managed-by" = "Helmraiser"))' -j > $out
    ''));

  # Marker to remove an attribute in `update`.
  removed = {_type = "anqou.net/removed";};

  # Marker to append/insert a value in `update`.
  added = value: {
    _type = "anqou.net/added";
    inherit value;
  };

  # cf. lib.attrsets.recursiveUpdate; a function in `rhs` is applied to the
  # corresponding value of `lhs` (or `null`).
  update = lhs: rhs: let
    isRemoved = v: v == removed;
    isAdded = v: builtins.isAttrs v && (v._type or null) == "anqou.net/added";
    f = attrPath:
      lib.attrsets.zipAttrsWith (
        name: values: let
          here = attrPath ++ [name];
          lhs = builtins.elemAt values 1;
          rhs = builtins.head values;
        in
          if builtins.isFunction rhs
          then
            rhs (
              if builtins.length values == 1
              then null
              else lhs
            )
          else if isAdded rhs
          then
            if builtins.length values == 1
            then rhs.value
            else lhs ++ rhs.value
          else if builtins.length values == 1 || !(builtins.isAttrs lhs && builtins.isAttrs rhs) || isRemoved rhs
          then rhs
          else f here values
      );
  in
    lib.attrsets.filterAttrsRecursive (_: v: !isRemoved v) (f [] [rhs lhs]);

  # Recursively drop null values.
  prune = value:
    if builtins.isList value
    then lib.lists.map prune (lib.lists.remove null value)
    else if builtins.isAttrs value
    then lib.attrsets.mapAttrs (_: prune) (lib.attrsets.filterAttrs (_: v: v != null) value)
    else value;

  # Build an environment: a named list of manifests. Each item is a manifest,
  # an attrset of manifests (e.g. a `helm` result), or a (nested) list of them.
  mkEnvironment = {
    name,
    namespace,
  }: manifests: {
    inherit name;
    manifests = let
      flattened1 = lib.lists.flatten manifests;
      unwrapped =
        lib.lists.map
        (
          src:
            assert builtins.isAttrs src;
              if src ? kind
              then src
              else lib.attrsets.attrValues src
        )
        flattened1;
      flattened2 = lib.lists.flatten unwrapped;
      pruned = let
        ms = lib.lists.map prune flattened2;
        manifestWithoutKind = lib.lists.findFirst (m: !(m ? kind)) null ms;
      in
        # every manifest should have a kind.
        lib.debug.traceIf (manifestWithoutKind != null) manifestWithoutKind ms;

      # cf. https://github.com/grafana/tanka/blob/18d2a59ca6abcbef2d1102621d3ca0a57e95908b/pkg/process/namespace.go#L17
      clusterWideKinds =
        lib.genAttrs [
          "APIService"
          "CertificateSigningRequest"
          "ClusterRole"
          "ClusterRoleBinding"
          "ComponentStatus"
          "CSIDriver"
          "CSINode"
          "CustomResourceDefinition"
          "MutatingWebhookConfiguration"
          "Namespace"
          "Node"
          "NodeMetrics"
          "PersistentVolume"
          "PodSecurityPolicy"
          "PriorityClass"
          "RuntimeClass"
          "SelfSubjectAccessReview"
          "SelfSubjectRulesReview"
          "StorageClass"
          "SubjectAccessReview"
          "TokenReview"
          "ValidatingWebhookConfiguration"
          "VolumeAttachment"
        ]
        (_: true);

      augmented =
        lib.lists.map (
          manifest:
            if
              builtins.hasAttr manifest.kind clusterWideKinds
              || (manifest ? metadata.namespace)
            then manifest
            else update manifest {metadata.namespace = namespace;}
        )
        pruned;
    in
      augmented;
  };

  # Build a tree of YAML manifests, one file per manifest, from environments.
  buildManifests = name: envs:
    pkgs.runCommand name {
      nativeBuildInputs = [pkgs.go-jsonnet];
      src = pkgs.writers.writeJSON "${name}-manifests.json" envs;
    } ''
      cat <<EOS > convert.jsonnet
      local src = std.parseJson(importstr "$src");
      {
        ["%s/%s_%s_%s.yaml" %
          local metadata = v.manifest.metadata;
          [
            v.environment,
            v.manifest.kind,
            metadata.name,
            if "namespace" in metadata then metadata.namespace else "",
          ]
        ]:
          std.manifestYamlDoc(v.manifest, quote_keys=false)
      for v in [
        {
          environment: env.name,
          manifest: manifest,
        }
        for env in src
        for manifest in env.manifests
      ]
      }
      EOS
      mkdir $out
      jsonnet -c -S -m $out convert.jsonnet
    '';

  persistentVolumeClaim = {
    name,
    accessModes,
    storageClassName,
    resourcesRequestsStorage,
    namespace ? null,
    labels ? null,
    annotations ? null,
    volumeMode ? null,
  }: {
    apiVersion = "v1";
    kind = "PersistentVolumeClaim";
    metadata = {
      inherit name namespace labels annotations;
    };
    spec = {
      inherit accessModes storageClassName volumeMode;
      resources = {
        requests = {
          storage = resourcesRequestsStorage;
        };
      };
    };
  };

  ingress = {
    name,
    namespace ? null,
    annotations ? null,
    rules ? null,
    tls ? null,
    ingressClassName ? null,
    defaultBackend ? null,
  }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "Ingress";
    metadata = {
      inherit name namespace annotations;
    };
    spec = {
      inherit ingressClassName rules tls defaultBackend;
    };
  };

  secret = {
    name,
    type ? null,
    namespace ? null,
    data ? null,
    stringData ? null,
  }: {
    apiVersion = "v1";
    kind = "Secret";
    metadata = {
      inherit name namespace;
    };
    inherit type data stringData;
  };

  service = {
    name,
    namespace ? null,
    labels ? null,
    selector ? null,
    ports ? null,
    clusterIP ? null,
    type ? null,
    loadBalancerClass ? null,
  }: {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      inherit name namespace labels;
    };
    spec = {
      inherit type loadBalancerClass selector ports clusterIP;
    };
  };

  servicePort = {
    port,
    name ? null,
    protocol ? null,
    targetPort ? null,
  }: {
    inherit name port protocol targetPort;
  };

  deployment = {
    name,
    namespace ? null,
    annotations ? null,
    replicas ? 1,
    selector ? null,
    podLabels ? null,
    volumes ? null,
    containers ? null,
    strategy ? null,
    serviceName ? null,
    nodeSelector ? null,
    securityContext ? null,
    serviceAccountName ? null,
    imagePullSecrets ? null,
    initContainers ? null,
    runtimeClassName ? null,
  }: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      inherit name namespace annotations;
    };
    spec = {
      inherit replicas strategy selector serviceName;
      template = {
        metadata = {
          labels = podLabels;
        };
        spec = {
          inherit imagePullSecrets nodeSelector volumes initContainers containers securityContext serviceAccountName runtimeClassName;
        };
      };
    };
  };

  container = {
    name,
    image,
    command ? null,
    volumeMounts ? null,
    envFrom ? null,
    env ? null,
    ports ? null,
    resources ? null,
    livenessProbe ? null,
    readinessProbe ? null,
    args ? null,
    securityContext ? null,
  }: {
    inherit name image command args volumeMounts envFrom env ports resources livenessProbe readinessProbe securityContext;
  };

  port = {
    name,
    containerPort,
    protocol ? null,
  }: {
    inherit name containerPort protocol;
  };

  secretRef = {name}: {
    secretRef = {
      inherit name;
    };
  };

  configMap = {
    name,
    namespace ? null,
    labels ? null,
    data ? null,
  }: {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      inherit name namespace labels;
    };
    inherit data;
  };

  volumePersistentVolumeClaim = {
    name,
    claimName,
  }: {
    inherit name;
    persistentVolumeClaim = {
      inherit claimName;
    };
  };

  vmrule = {
    name,
    rules,
    namespace ? null,
  }: {
    apiVersion = "operator.victoriametrics.com/v1beta1";
    kind = "VMRule";
    metadata = {
      inherit name namespace;
    };
    spec = {
      groups = [
        {
          concurrency = 2;
          interval = "30s";
          name = "vmcluster";
          params = {};
          inherit rules;
        }
      ];
    };
  };

  namespace = {
    name,
    labels ? null,
  }: {
    apiVersion = "v1";
    kind = "Namespace";
    metadata = {
      inherit name labels;
    };
  };

  networkpolicy = {
    name,
    namespace ? null,
    podSelector ? null,
    policyTypes ? null,
    egress ? null,
    ingress ? null,
  }: {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata = {
      inherit name namespace;
    };
    spec = {
      inherit podSelector policyTypes egress ingress;
    };
  };

  application = {
    name,
    namespace ? null,
    project ? null,
    repoURL ? null,
    targetRevision ? null,
    path ? null,
    prune ? null,
    selfHeal ? null,
    server ? null,
    destinationNamespace ? null,
    finalizers ? null,
    syncOptions ? null,
    automatedEnabled ? null,
  }: {
    apiVersion = "argoproj.io/v1alpha1";
    kind = "Application";
    metadata = {
      inherit name namespace finalizers;
    };
    spec = {
      project = project;
      source = {
        repoURL = repoURL;
        targetRevision = targetRevision;
        path = path;
      };
      syncPolicy = {
        automated = {
          enabled = automatedEnabled;
          prune = prune;
          selfHeal = selfHeal;
        };
        syncOptions = syncOptions;
      };
      destination = {
        server = server;
        namespace = destinationNamespace;
      };
    };
  };

  sealedsecret = {
    name,
    namespace ? null,
    template ? {},
    encryptedData,
  }: {
    kind = "SealedSecret";
    apiVersion = "bitnami.com/v1alpha1";
    metadata = {
      inherit name namespace;
    };
    spec = {
      inherit template encryptedData;
    };
  };

  statefulSet = {
    name,
    namespace ? null,
    selector ? null,
    serviceName ? null,
    replicas ? 1,
    podLabels ? null,
    terminationGracePeriodSeconds ? null,
    containers ? null,
    volumes ? null,
    annotations ? null,
    imagePullSecrets ? null,
    tolerations ? null,
    nodeSelector ? null,
    initContainers ? null,
    securityContext ? null,
  }: {
    apiVersion = "apps/v1";
    kind = "StatefulSet";
    metadata = {
      inherit name namespace annotations;
    };
    spec = {
      inherit selector serviceName replicas;
      template = {
        metadata = {
          labels = podLabels;
        };
        spec = {
          inherit imagePullSecrets terminationGracePeriodSeconds initContainers containers volumes tolerations nodeSelector securityContext;
        };
      };
    };
  };

  volumeConfigMap = {
    name,
    configMapName,
    configMapItems ? null,
  }: {
    inherit name;
    configMap = {
      name = configMapName;
      items = configMapItems;
    };
  };

  probeExecCommand = {
    command,
    initialDelaySeconds ? null,
    periodSeconds ? null,
  }: {
    exec = {inherit command;};
    inherit initialDelaySeconds periodSeconds;
  };

  volumeMount = {
    name,
    mountPath,
    subPath ? null,
    readOnly ? null,
  }: {
    inherit name mountPath subPath readOnly;
  };

  volumeEmptyDir = {name}: {
    inherit name;
    emptyDir = {};
  };

  envVar = {
    name,
    value,
  }: {
    inherit name value;
  };

  volumeHostPath = {
    name,
    path,
    type ? null,
  }: {
    inherit name;
    hostPath = {
      inherit path type;
    };
  };

  vmPodScrape = {
    name,
    namespace,
    spec,
  }: {
    apiVersion = "operator.victoriametrics.com/v1beta1";
    kind = "VMPodScrape";
    metadata = {
      inherit name namespace;
    };
    inherit spec;
  };

  probeTCPSocket = {
    port,
    initialDelaySeconds ? null,
    periodSeconds ? null,
  }: {
    inherit initialDelaySeconds periodSeconds;
    tcpSocket = {
      inherit port;
    };
  };

  configMapRef = {name}: {
    configMapRef = {
      inherit name;
    };
  };

  probeHttpGet = {
    path,
    port,
  }: {
    httpGet = {
      inherit path port;
    };
  };

  recreate = {
    type = "Recreate";
  };

  vmServiceScrape = {
    name,
    namespace,
    spec,
  }: {
    apiVersion = "operator.victoriametrics.com/v1beta1";
    kind = "VMServiceScrape";
    metadata = {
      inherit name namespace;
    };
    inherit spec;
  };

  cronJob = {
    name,
    schedule,
    containers,
    namespace ? null,
    timeZone ? null,
    concurrencyPolicy ? null,
    successfulJobsHistoryLimit ? null,
    restartPolicy ? null,
    volumes ? null,
    nodeSelector ? null,
    securityContext ? null,
    serviceAccountName ? null,
    suspend ? null,
    podLabels ? null,
    tolerations ? null,
  }: {
    apiVersion = "batch/v1";
    kind = "CronJob";
    metadata = {
      inherit name namespace;
    };
    spec = {
      inherit suspend timeZone schedule concurrencyPolicy successfulJobsHistoryLimit;
      jobTemplate = {
        spec = {
          template = {
            metadata =
              if podLabels == null
              then null
              else {
                labels = podLabels;
              };
            spec = {
              inherit restartPolicy volumes containers nodeSelector securityContext serviceAccountName tolerations;
            };
          };
        };
      };
    };
  };
}
