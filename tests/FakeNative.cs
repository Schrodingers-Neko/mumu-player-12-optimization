using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Security.Cryptography;

// Only accesses the test directory supplied by the regression harness.
public static class FakeNative
{
    static string Root, Scenario, Remote;
    static readonly string Target = "/system/priv-app/Lawnchair/Lawnchair.apk";
    static readonly string ModuleApk = "/data/adb/modules/lawnchair/system/priv-app/Lawnchair/Lawnchair.apk";
    static string Map(string path) {
        string result = Path.GetFullPath(Path.Combine(Remote, path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar)));
        if (!result.StartsWith(Remote + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe fake remote path");
        return result;
    }
    static void Write(string path, string value) { Directory.CreateDirectory(Path.GetDirectoryName(path)); File.WriteAllText(path, value); }
    static bool Mounted { get { return File.Exists(Path.Combine(Root, "mounted")); } }
    static string Actual(string path) { return Map(path == Target && Mounted ? ModuleApk : path); }
    static string Hash(string path) { using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(path))).Replace("-", "").ToLowerInvariant(); }
    static int Fail(string message) { Console.Error.WriteLine(message); return 7; }
    public static int Main(string[] args) {
        Root = Environment.GetEnvironmentVariable("MUMU_TEST_ROOT");
        if (String.IsNullOrEmpty(Root) || !Directory.Exists(Root)) return Fail("Test root required");
        Scenario = Environment.GetEnvironmentVariable("MUMU_TEST_SCENARIO") ?? "success";
        Remote = Path.Combine(Root, "remote"); Directory.CreateDirectory(Remote);
        string role = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        File.AppendAllText(Path.Combine(Root, "calls.txt"), role + "\t" + String.Join("\t", args).Replace("\n", "\\n") + "\n");
        if (role == "pwsh" || role == "powershell") {
            Write(Path.Combine(Root, "wrapper-input.txt"), args.Last());
            return Int32.Parse(Environment.GetEnvironmentVariable("MUMU_TEST_WRAPPER_EXIT") ?? "0");
        }
        if (role == "java") {
            int cert = Array.IndexOf(args, "--verifySha256");
            if (cert < 0 || args[cert + 1] != "c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8" || !args.Contains("--onlyVerify")) return Fail("Wrong verification arguments");
            return Scenario == "bad-signature" ? Fail("Signature mismatch") : 0;
        }
        if (role == "native") {
            if (args.Length > 0 && args[0] == "fail") { Console.WriteLine("stdout diagnostic"); return Fail("stderr diagnostic"); }
            if (args.Length > 0 && args[0] == "sleep") { System.Threading.Thread.Sleep(5000); return 0; }
            if (args.Length > 0 && args[0] == "streams") { Console.Write(new string('x', 100000)); Console.Error.Write(new string('y', 100000)); return 0; }
            for (int i = 0; i < args.Length; i++) Write(Path.Combine(Root, "arg" + i + ".txt"), args[i]);
            return 0;
        }
        if (role == "mumu-cli") {
            if (Scenario == "cli-failure") return Fail("CLI failure");
            if (args[0] == "control") { Write(Path.Combine(Root, "launched"), "1"); return 0; }
            if (Scenario == "invalid-json") { Console.WriteLine("not json"); return 0; }
            string index = Scenario == "wrong-vm" ? "2" : args[2];
            bool started = Scenario != "stopped" && Scenario != "start-timeout" || Scenario == "stopped" && File.Exists(Path.Combine(Root, "launched"));
            string port = Scenario == "missing-port" ? "null" : "23456";
            Console.WriteLine("{\"index\":\"" + index + "\",\"error_code\":0,\"android_version\":\"15.0\",\"is_android_started\":" + started.ToString().ToLowerInvariant() + ",\"adb_port\":" + port + "}");
            return 0;
        }
        if (args[0] == "connect") { Console.WriteLine("connected"); return 0; }
        if (args.Length < 3 || args[0] != "-s" || args[1] != (Environment.GetEnvironmentVariable("MUMU_TEST_DEVICE") ?? "127.0.0.1:23456")) return Fail("Unexpected device");
        string action = args[2];
        if (action == "get-state") { Console.WriteLine(Scenario == "offline" ? "offline" : "device"); return 0; }
        if (action == "root") return 0;
        if (action == "install") {
            Write(Path.Combine(Root, "installed-path.txt"), args.Last());
            if (Scenario == "install-failure") return Fail("Failure [INSTALL_FAILED_INVALID_APK]");
            Console.WriteLine(Scenario == "install-no-success" ? "Failure [INSTALL_FAILED_INVALID_APK]" : "Success");
            return 0;
        }
        if (action == "pull") {
            if (Scenario == "pull-failure") return Fail("Pull failed");
            if (Scenario == "empty-backup") Write(args[4], ""); else File.Copy(Actual(args[3]), args[4], true);
            return 0;
        }
        if (action == "push") {
            if (Scenario == "push-failure") return Fail("Push failed");
            Directory.CreateDirectory(Path.GetDirectoryName(Map(args[4]))); File.Copy(args[3], Map(args[4]), true); return 0;
        }
        if (action != "shell") return Fail("Unknown action");
        string cmd = args[3];
        var paths = Regex.Matches(cmd, "'([^']*)'").Cast<Match>().Select(m => m.Groups[1].Value).ToArray();
        if (cmd == "id -u") { Console.WriteLine(Scenario == "no-root" ? "2000" : "0"); return 0; }
        if (cmd.Contains("/proc/mounts")) { Console.WriteLine(Mounted ? "MOUNTED" : "UNMOUNTED"); return 0; }
        if (cmd.StartsWith("if [ -s ")) {
            string path = paths[0];
            bool factoryView = path.Contains("mumu_lawnchair_factory_");
            string file = factoryView ? Map(Target) : Actual(path);
            Console.WriteLine(File.Exists(file) && new FileInfo(file).Length > 0 ? "PRESENT" : "MISSING"); return 0;
        }
        if (cmd.StartsWith("sha256sum ")) {
            string path = paths.Length > 0 ? paths[0] : cmd.Substring(10);
            Console.WriteLine((Scenario == "hash-mismatch" ? new string('0', 64) : Hash(Actual(path))) + "  " + path); return 0;
        }
        if (cmd.StartsWith("mkdir -p ") || cmd.StartsWith("touch ") || cmd.StartsWith("chmod ") || cmd.StartsWith("chown ") || cmd.StartsWith("rmdir ")) return 0;
        if (cmd.StartsWith("mount -o bind /system/priv-app/Lawnchair ")) return 0;
        if (cmd.StartsWith("mount -o bind ")) {
            if (Scenario == "mount-failure") return Fail("Mount failed");
            Write(Path.Combine(Root, "mounted"), "1"); return 0;
        }
        if (cmd.StartsWith("umount ")) {
            if (paths[0] == Target) {
                if (Scenario == "unmount-failure") return Fail("Unmount failed");
                File.Delete(Path.Combine(Root, "mounted"));
            }
            return 0;
        }
        if (cmd.StartsWith("cp ")) {
            if (Scenario == "copy-failure") return Fail("Copy failed");
            string destination = paths.Length > 1 ? paths[1] : cmd.Substring(cmd.LastIndexOf(' ') + 1);
            Directory.CreateDirectory(Path.GetDirectoryName(Map(destination))); File.Copy(Map(paths[0]), Map(destination), true); return 0;
        }
        if (cmd.StartsWith("cat > ")) return 0;
        if (cmd.StartsWith("rm -f ") || cmd.StartsWith("rm -rf ")) return 0;
        if (cmd == "pidof system_server") { Console.WriteLine(File.Exists(Path.Combine(Root, "restarted")) && Scenario != "restart-ignored" ? "102" : "101"); return 0; }
        if (cmd == "setprop ctl.restart zygote") { Write(Path.Combine(Root, "restarted"), "1"); return 0; }
        if (cmd == "getprop sys.boot_completed") { Console.WriteLine(Scenario == "ready-timeout" ? "0" : "1"); return 0; }
        if (cmd == "cmd package path app.lawnchair") { Console.WriteLine("package:" + Target); return 0; }
        if (cmd.StartsWith("cmd package install-existing") || cmd.StartsWith("cmd role add-role-holder") || cmd.StartsWith("am start ")) return 0;
        if (cmd.StartsWith("cmd role get-role-holders")) { Console.WriteLine(Scenario == "wrong-role" ? "other.launcher" : "app.lawnchair"); return 0; }
        if (cmd == "pidof app.lawnchair") { if (Scenario == "launcher-timeout") return 1; Console.WriteLine("1234"); return 0; }
        if (cmd == "pm clear app.lawnchair") { Console.WriteLine("Success"); return 0; }
        if (cmd == "ime list -a -s" || cmd == "ime list -s") { if (Scenario != "missing-ime") Console.WriteLine("helium314.keyboard/.latin.LatinIME"); return 0; }
        if (cmd.StartsWith("ime enable ") || cmd.StartsWith("ime set ")) { return Scenario == "ime-failure" ? Fail("IME activation failed") : 0; }
        if (cmd == "settings get secure default_input_method") { Console.WriteLine(Scenario == "ime-unverified" ? "sogou/.Ime" : "helium314.keyboard/.latin.LatinIME"); return 0; }
        if (cmd.StartsWith("pm list packages")) {
            string package = cmd.Substring(cmd.LastIndexOf(' ') + 1);
            if (package == "com.nemu.googleinstaller") {
                if (!File.Exists(Path.Combine(Root, "uninstalled"))) Console.WriteLine("package:" + package);
            } else if (!cmd.Contains(" -d ") || Scenario == "already-disabled" || File.Exists(Path.Combine(Root, "disabled-" + package))) Console.WriteLine("package:" + package);
            return 0;
        }
        if (cmd.StartsWith("pm uninstall")) { Write(Path.Combine(Root, "uninstalled"), "1"); Console.WriteLine("Success"); return 0; }
        if (cmd.StartsWith("am force-stop")) return 0;
        if (cmd.StartsWith("pm disable-user")) { Write(Path.Combine(Root, "disabled-" + cmd.Substring(cmd.LastIndexOf(' ') + 1)), "1"); return 0; }
        return Fail("Unhandled fake command: " + cmd);
    }
}
