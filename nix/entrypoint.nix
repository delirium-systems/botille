{
  pkgs,
  imageClosureInfo,
  home,
  hmActivation,
}:
pkgs.replaceVarsWith {
  src = ./entrypoint.sh;
  isExecutable = true;
  replacements = {
    inherit imageClosureInfo home hmActivation;
  };
}
