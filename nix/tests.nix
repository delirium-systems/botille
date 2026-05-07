{ pkgs, launcher }:
let
  testUser = "tester";

  tools = [
    {
      name = "claude-code";
      bin = "claude";
    }
    {
      name = "gemini-cli";
      bin = "gemini";
    }
    {
      name = "copilot-cli";
      bin = "copilot";
    }
    {
      name = "opencode";
      bin = "opencode";
    }
    {
      name = "pi-coding-agent";
      bin = "pi";
    }
  ];

  runAs = cmd: "su -l ${testUser} -c ${pkgs.lib.escapeShellArg cmd}";

  subtestScript = builtins.concatStringsSep "\n" (
    map (t: ''
      with subtest("${t.name}"):
          output = machine.succeed("${runAs "${pkgs.lib.getExe launcher} ${t.bin} --version"}")
          print(f"${t.name}: {output.strip()}")
    '') tools
  );
in
{
  ai-tools = pkgs.testers.runNixOSTest {
    name = "botille-ai-tools";
    nodes.machine = {
      virtualisation = {
        podman.enable = true;
        diskSize = 32768;
        memorySize = 2048;
      };
      users.users.${testUser} = {
        isNormalUser = true;
        extraGroups = [ "podman" ];
        subUidRanges = [
          {
            startUid = 100000;
            count = 65536;
          }
        ];
        subGidRanges = [
          {
            startGid = 100000;
            count = 65536;
          }
        ];
      };
    };
    testScript = ''
      machine.wait_for_unit("default.target")

      ${subtestScript}
    '';
  };
}
