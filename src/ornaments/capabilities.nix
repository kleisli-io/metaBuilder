{ mb, api, ... }:

let
  inherit (mb.operations) capability capabilityCategory capabilitySet runtimeTypes;

  # Map a closed RuntimeType sum constructor to its JSON-Schema type
  # string. The mapping is the eval-time → runtime-tool boundary; the
  # spec carries the typed sum, the schema artifact carries the
  # canonical JSON-Schema name.
  runtimeTypeToJsonSchemaType = rt:
    if rt._con == "RTString" then "string"
    else if rt._con == "RTInt" then "integer"
    else if rt._con == "RTBool" then "boolean"
    else if rt._con == "RTObject" then "object"
    else if rt._con == "RTArray" then "array"
    else throw "metaBuilder.ornaments.capabilities.schema: unknown runtime type tag '${rt._con}'";

  paramToProperty = p: {
    type = runtimeTypeToJsonSchemaType p.type;
    inherit (p) description;
  };

  schema = cap:
    let
      properties = builtins.listToAttrs (map (p: { name = p.name; value = paramToProperty p; }) cap.params);
      required = map (p: p.name) (builtins.filter (p: p.required) cap.params);
    in
    {
      type = "object";
      inherit properties required;
      returns = runtimeTypeToJsonSchemaType cap.returns;
      inherit (cap) description;
    };

  setSchemas = capSet:
    let
      fromCategories = builtins.concatMap
        (cat: map (cap: { name = cap.name; value = schema cap // { category = cat.name; }; }) cat.capabilities)
        capSet.categories;
      fromCustom = map (cap: { name = cap.name; value = schema cap // { category = "custom"; }; }) capSet.custom;
    in
    builtins.listToAttrs (fromCategories ++ fromCustom);

  contains = mb.descriptions.runtime.hasCapability;

  # Built-in capability categories. Each is a typed CapabilityCategory.
  # Consumer extension goes through `category { ... }`, not through
  # string-keyed attrset merge.
  builtins' = {
    lifecycle = capabilityCategory {
      name = "lifecycle";
      description = "Service lifecycle management";
      capabilities = [
        (capability { name = "start"; description = "Start service"; params = [ ]; returns = runtimeTypes.RTObject; })
        (capability { name = "stop"; description = "Stop service"; params = [ ]; returns = runtimeTypes.RTObject; })
        (capability { name = "health"; description = "Check service health"; params = [ ]; returns = runtimeTypes.RTObject; })
      ];
    };

    crud = capabilityCategory {
      name = "crud";
      description = "Create, read, update, delete operations";
      capabilities = [
        (capability {
          name = "create";
          description = "Create a resource";
          params = [
            (mb.operations.param { name = "data"; description = "Resource data"; type = runtimeTypes.RTObject; required = true; })
          ];
          returns = runtimeTypes.RTObject;
        })
        (capability {
          name = "read";
          description = "Read a resource";
          params = [
            (mb.operations.param { name = "id"; description = "Resource identifier"; type = runtimeTypes.RTString; required = true; })
          ];
          returns = runtimeTypes.RTObject;
        })
        (capability {
          name = "update";
          description = "Update a resource";
          params = [
            (mb.operations.param { name = "id"; description = "Resource identifier"; type = runtimeTypes.RTString; required = true; })
            (mb.operations.param { name = "data"; description = "Updated data"; type = runtimeTypes.RTObject; required = true; })
          ];
          returns = runtimeTypes.RTObject;
        })
        (capability {
          name = "delete";
          description = "Delete a resource";
          params = [
            (mb.operations.param { name = "id"; description = "Resource identifier"; type = runtimeTypes.RTString; required = true; })
          ];
          returns = runtimeTypes.RTObject;
        })
      ];
    };

    streaming = capabilityCategory {
      name = "streaming";
      description = "Streaming and pub-sub operations";
      capabilities = [
        (capability {
          name = "subscribe";
          description = "Subscribe to a channel";
          params = [
            (mb.operations.param { name = "channel"; description = "Channel identifier"; type = runtimeTypes.RTString; required = true; })
          ];
          returns = runtimeTypes.RTObject;
        })
        (capability {
          name = "publish";
          description = "Publish to a channel";
          params = [
            (mb.operations.param { name = "channel"; description = "Channel identifier"; type = runtimeTypes.RTString; required = true; })
            (mb.operations.param { name = "data"; description = "Data to publish"; type = runtimeTypes.RTObject; required = true; })
          ];
          returns = runtimeTypes.RTObject;
        })
      ];
    };
  };

  value = {
    capability = capability;
    category = capabilityCategory;
    set = capabilitySet;
    inherit schema setSchemas contains;
    builtins = builtins';
  };

in
api.mk {
  description = "capabilities ornament: typed capability vocabulary over the runtime.* effect algebra. Built-in `lifecycle`/`crud`/`streaming` categories, smart constructors `capability`/`category`/`set`, and a `schema` eliminator producing JSON-Schema artifacts at the eval-time → runtime-tool boundary.";
  doc = ''
    # Capabilities

    Typed capability vocabulary built on the `runtime.*` effect
    algebra. The underlying datatypes (`CapabilitySchema`,
    `CapabilityCategory`, `CapabilitySet`) live in
    `mb.descriptions`; this ornament adds three things consumers
    actually reach for:

    - **Smart constructors** as terse aliases:
      `capabilities.capability { name; description?; params?; returns?; }`
      `capabilities.category { name; description?; capabilities?; }`
      `capabilities.set { categories?; custom?; }`

    - **Built-in categories** as typed values addressable as
      `capabilities.builtins.{lifecycle,crud,streaming}`. Each is a
      fully-typed `CapabilityCategory`. Consumer extension goes
      through `H.ornament` on the closed kernel sum, not through
      string-keyed attrset merge.

    - **Schema eliminator** `schema : CapabilitySchema → AttrSet`
      produces a JSON-Schema-shaped attrset suitable for MCP/API
      tooling. `setSchemas : CapabilitySet → AttrSet` flattens an
      entire set, attaching a `category` tag to each entry.
  '';
  inherit value;
  tests =
    let
      cs = capabilitySet { categories = [ builtins'.lifecycle builtins'.crud ]; };
    in
    {
      "lifecycle-builtin-is-typed-CapabilityCategory" = {
        expr = {
          inherit (builtins'.lifecycle) _con name;
          capCount = builtins.length builtins'.lifecycle.capabilities;
          capNames = map (c: c.name) builtins'.lifecycle.capabilities;
        };
        expected = {
          _con = "MetaBuilderCapabilityCategory";
          name = "lifecycle";
          capCount = 3;
          capNames = [ "start" "stop" "health" ];
        };
      };

      "crud-builtin-carries-typed-params" = {
        expr =
          let
            createCap = builtins.head builtins'.crud.capabilities;
            dataParam = builtins.head createCap.params;
          in
          {
            createName = createCap.name;
            paramName = dataParam.name;
            paramTypeTag = dataParam.type._con;
            paramRequired = dataParam.required;
          };
        expected = {
          createName = "create";
          paramName = "data";
          paramTypeTag = "RTObject";
          paramRequired = true;
        };
      };

      "streaming-builtin-publish-has-two-required-params" = {
        expr =
          let
            publishCap = builtins.elemAt builtins'.streaming.capabilities 1;
          in
          {
            name = publishCap.name;
            paramNames = map (p: p.name) publishCap.params;
            allRequired = builtins.all (p: p.required) publishCap.params;
          };
        expected = {
          name = "publish";
          paramNames = [ "channel" "data" ];
          allRequired = true;
        };
      };

      "schema-emits-jsonSchema-shape-for-zero-param-cap" = {
        expr = schema (builtins.head builtins'.lifecycle.capabilities);
        expected = {
          type = "object";
          properties = { };
          required = [ ];
          returns = "object";
          description = "Start service";
        };
      };

      "schema-emits-properties-and-required-for-crud-create" = {
        expr =
          let
            createCap = builtins.head builtins'.crud.capabilities;
          in
          schema createCap;
        expected = {
          type = "object";
          properties = {
            data = { type = "object"; description = "Resource data"; };
          };
          required = [ "data" ];
          returns = "object";
          description = "Create a resource";
        };
      };

      "setSchemas-flattens-categories-with-category-tag" = {
        expr =
          let
            flat = setSchemas cs;
          in
          {
            keys = builtins.sort builtins.lessThan (builtins.attrNames flat);
            startCategory = flat.start.category;
            createCategory = flat.create.category;
          };
        expected = {
          keys = [ "create" "delete" "health" "read" "start" "stop" "update" ];
          startCategory = "lifecycle";
          createCategory = "crud";
        };
      };

      "set-typecheck-passes-with-builtin-categories" = {
        expr = cs._con;
        expected = "MetaBuilderCapabilitySet";
      };

      "schema-rejects-unknown-runtime-type-tag" = {
        expr = (builtins.tryEval (builtins.deepSeq
          (schema {
            name = "broken";
            description = "";
            params = [{ name = "x"; description = ""; type = { _con = "RTBogus"; }; required = true; }];
            returns = runtimeTypes.RTObject;
          })
          null)).success;
        expected = false;
      };
    };
}
