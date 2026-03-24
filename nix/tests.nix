{ pkgs, launcher }:
let
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
    {
      name = "openclaw";
      bin = "openclaw";
    }
  ];

  subtestScript = builtins.concatStringsSep "\n" (
    map (t: ''
      with subtest("${t.name}"):
          output = machine.succeed("${pkgs.lib.getExe launcher} ${t.bin} --version")
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
    };
    testScript = ''
      machine.wait_for_unit("default.target")

      ${subtestScript}
    '';
  };
}
