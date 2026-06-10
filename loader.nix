{ lib, fx, api }:

let
  isNixFile = name: type:
    type == "regular"
    && lib.hasSuffix ".nix" name
    && !(builtins.elem name [ "api.nix" "module.nix" ]);

  wrapNamespace = value:
    api.mk {
      doc = "";
      description = "";
      value = value;
      tests = { };
    };

  loadSplitModule = { dir, ctx, entries, subDirs }:
    let
      partNames = builtins.attrNames (lib.filterAttrs isNixFile entries);
      importPart = n: s:
        import (dir + "/${n}") (ctx // { self = s; });
      isWrap = v:
        builtins.isAttrs v && (v._type or null) == "metaBuilder-api";
      unwrapTop = v: if isWrap v then v.value else v;
      selves = lib.fix (s:
        let
          partsScope = builtins.foldl'
            (acc: n:
              let
                part = importPart n s.selfForParts;
                scope = part.scope;
                collisions = lib.intersectLists
                  (builtins.attrNames acc)
                  (builtins.attrNames scope);
              in
              if collisions != [ ]
              then throw "metaBuilder.readSrc: ${toString dir}: duplicate binding(s) ${toString collisions}"
              else acc // scope
            )
            { }
            partNames;
          sdCollisions = lib.intersectLists
            (builtins.attrNames partsScope)
            (builtins.attrNames subDirs);
        in
        if sdCollisions != [ ]
        then throw "metaBuilder.readSrc: ${toString dir}: subdirectory name(s) collide with scope binding(s): ${toString sdCollisions}"
        else {
          inherit partsScope;
          selfForParts = (builtins.mapAttrs (_: unwrapTop) partsScope) // subDirs;
          selfRaw = partsScope // subDirs;
        });

      partTests = builtins.foldl'
        (acc: n:
          let
            part = importPart n selves.selfForParts;
            t = part.tests or { };
            collisions = lib.intersectLists
              (builtins.attrNames acc)
              (builtins.attrNames t);
          in
          if collisions != [ ]
          then throw "metaBuilder.readSrc: ${toString dir}: duplicate test name(s) ${toString collisions}"
          else acc // t
        )
        { }
        partNames;
    in
    import (dir + "/module.nix") (ctx // {
      self = selves.selfRaw;
      inherit partTests;
    });

  readSrc = dir: ctx:
    let
      entries = builtins.readDir dir;
    in
    if entries ? ".skip-subtree" then wrapNamespace { }
    else
      let
        isSplitModule = entries ? "module.nix";
        shouldTraverseDir = name: type:
          type == "directory"
          && !(builtins.pathExists (dir + "/${name}/.skip"));
        subDirNames = builtins.attrNames
          (lib.filterAttrs shouldTraverseDir entries);
        fileNames = builtins.attrNames (lib.filterAttrs isNixFile entries);
        fileAttrName = name: lib.removeSuffix ".nix" name;
        subDirs = lib.genAttrs subDirNames
          (name: readSrc (dir + "/${name}") ctx);
      in
      if isSplitModule
      then loadSplitModule { inherit dir ctx entries subDirs; }
      else
        let
          imported = builtins.listToAttrs (map
            (name: {
              name = fileAttrName name;
              value = import (dir + "/${name}") ctx;
            })
            fileNames);
        in
        wrapNamespace (imported // subDirs);
in
{
  inherit readSrc;
}
