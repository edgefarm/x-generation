local k8s = import 'functions.jsonnet';

local s = {
  config: std.parseJson(std.extVar('config')),
  crd: std.parseJson(std.extVar('crd')),
  data: std.parseJson(std.extVar('data')),
};

local plural = k8s.NameToPlural(s.config);
local fqdn = k8s.FQDN(plural, s.config.group);
local resourceFqdn = k8s.FQDN(s.crd.names.kind, s.crd.group);
local version = k8s.GetVersion(s.crd, s.config.version);

local uidFieldPath = k8s.GetUIDFieldPath(s.config);
local uidFieldName = 'uid';

local definitionSpec = k8s.GenerateSchema(
  version.schema.openAPIV3Schema.properties.spec,
  s.config,
  ['spec'],
);

local definitionStatus = k8s.GenerateSchema(
  version.schema.openAPIV3Schema.properties.status,
  s.config,
  ['status'],
);

{
  definition: {
    apiVersion: 'apiextensions.crossplane.io/v1',
    kind: 'CompositeResourceDefinition',
    metadata: {
      name: "composite"+fqdn,
    },
    spec: {
      claimNames: {
        kind: s.config.name,
        plural: plural,
      },
      [if std.objectHas(s.config, "connectionSecretKeys") then "connectionSecretKeys"]:
        s.config.connectionSecretKeys,
      group: s.config.group,
      names: {
        kind: "Composite"+s.config.name,
        plural: "composite"+plural,
        categories: k8s.GenerateCategories(s.config.group),
      },
      versions: [
        {
          name: version.name,
          referenceable: version.storage,
          served: version.served,
          schema: {
            openAPIV3Schema: {
              properties: {
                spec: definitionSpec,
                status:
                  definitionStatus
                  {
                    properties+: {
                      [uidFieldName]: {
                        description: 'The unique ID of this %s resource reported by the provider' % [s.config.name],
                        type: 'string',
                      },
                      observed: {
                        description: 'Freeform field containing information about the observed status.',
                        type: 'object',
                        "x-kubernetes-preserve-unknown-fields": true,
                      },
                    },
                  },
              },
            },
          },
          additionalPrinterColumns: k8s.FilterPrinterColumns(version.additionalPrinterColumns),
        },
      ],
      // defaultCompositionRef: {
      //   name: k8s.GetDefaultComposition(s.config.compositions),
      // },
    },
  },
} + {
  ['composition-' + composition.name]: {
    apiVersion: 'apiextensions.crossplane.io/v1',
    kind: 'Composition',
    metadata: {
      name: "composite" + composition.name + "." + s.config.group,
      labels: k8s.GenerateLabels(composition.provider),
    },
    spec: {
      local spec = self,
      [if std.objectHas(s.config, "connectionSecretKeys") then "writeConnectionSecretsToNamespace"]:
        'crossplane-system',
      compositeTypeRef: {
        apiVersion: s.config.group + '/' + s.config.version,
        kind: "Composite"+s.config.name,
      },
      patchSets: [
        {
          name: 'Name',
          patches: [{
            type: 'FromCompositeFieldPath',
            fromFieldPath: 'metadata.labels[crossplane.io/claim-name]',
            toFieldPath: if std.objectHas(s.config, 'patchExternalName') && s.config.patchExternalName == false then 'metadata.name' else 'metadata.annotations[crossplane.io/external-name]',
          }],
        },
        {
          name: 'Common',
          patches: k8s.GenOptionalPatchFrom(
            // Patch crossplane well-known metadata fields
            k8s.GenGlobalLabel([
              'claim-name',
              'claim-namespace',
              'composite',
            ])
            +
            // Patch company-specific fields
            k8s.GenCompanyControllingLabel([
              'cost-reference',
              'owner',
              'product',
            ])
            +
            k8s.GenCompanyGenericLabel([
              'account',
              'zone',
              'environment',
              'protection-requirement',
              'repourl',
            ])
            +
            k8s.GenExternalGenericLabel([
              'external-name'
            ])
          ),
        },
        {
          name: 'Parameters',
          patches: k8s.GenOptionalPatchFrom(
            k8s.GeneratePatchPaths(
              definitionSpec.properties,
              s.config,
              ['spec']
            )
          ),
        },
      ],
      resources: [
        {
          local resource = self,
          name: s.crd.spec.names.kind,
          base: {
            apiVersion: s.crd.spec.group + '/' + s.config.version,
            kind: resource.name,
            spec: {
              providerConfigRef: {
                name: 'default',
              },
              [if std.objectHas(s.config, "connectionSecretKeys") then "writeConnectionSecretToRef"]:
                {
                  namespace: 'crossplane-system'
                },
            },
          } + k8s.SetDefaults(s.config),
          patches: [
            {
              type: 'PatchSet',
              patchSetName: ps.name,
            }
            for ps in spec.patchSets
          ] + k8s.GenOptionalPatchTo(
            k8s.GeneratePatchPaths(
              definitionStatus.properties,
              s.config,
              ['status']
            )
          )+ k8s.GenPatch(
              'ToCompositeFieldPath',
              uidFieldPath,
              'status.%s' % [uidFieldName],
              'fromFieldPath',
              'toFieldPath',
              'Optional'
          )+ k8s.GenPatch(
              'ToCompositeFieldPath',
              'status.conditions',
              'status.observed.conditions',
              'fromFieldPath',
              'toFieldPath',
              'Optional'
          )+
          (if std.objectHas(s.config, "connectionSecretKeys") then           
            k8s.GenSecretPatch(
                'FromCompositeFieldPath',
                'metadata.uid',
                'spec.writeConnectionSecretToRef.name',
                'fromFieldPath',
                'toFieldPath',
                'Optional'
            )else []),
          [if std.objectHas(s.config, "connectionSecretKeys") then "connectionDetails"]:
            [
              {
                fromConnectionSecretKey: keys,
              },
              for keys in s.config.connectionSecretKeys
            ],
        },
      ],
    },
  }
  for composition in s.config.compositions
}
