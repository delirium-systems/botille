{
  pkgs,
  imageClosureInfo,
  closureInfoReg,
  home,
  hmActivation,
}:
pkgs.replaceVarsWith {
  src = ./entrypoint.sh;
  isExecutable = true;
  replacements = {
    inherit
      imageClosureInfo
      closureInfoReg
      home
      hmActivation
      ;
  };
}
