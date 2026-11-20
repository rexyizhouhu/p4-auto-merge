using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;

[assembly: AssemblyTitle("P4 Auto Merge")]
[assembly: AssemblyDescription("P4 auto merge with safe resolve and manual conflict handling")]
[assembly: AssemblyProduct("P4 Auto Merge")]
[assembly: AssemblyVersion("1.0.6.0")]
[assembly: AssemblyFileVersion("1.0.6.0")]
[assembly: AssemblyInformationalVersion("1.0.6")]

internal static class Program
{
    private const string GuiName = "P4AutoMerge.ps1";
    private const string CoreName = "P4AutoMerge.Core.psm1";
    private static readonly string[] RuntimeNames = {
        GuiName, CoreName, "P4AutoMerge.Update.psm1", "P4AutoMerge.UpdateUi.ps1"
    };
    private const int UpdateExitCode = 42;
    private const int ExtractTimeoutMs = 15000;
    private const string RunningMutex = "Local\\FlamesTools.P4AutoMerge.Running";
    private static readonly Encoding Utf8 = new UTF8Encoding(false);

    [STAThread]
    private static int Main(string[] args)
    {
        bool diagnostic = args.Length != 0;
        try
        {
            return RunApplication(args);
        }
        catch (Exception error)
        {
            string path = SaveDiagnostic(error.ToString());
            if (diagnostic)
                WriteDiagnosticOutput(error.Message + Environment.NewLine + path, true);
            else
                MessageBox.Show("工具启动失败：" + error.Message + "\n\n诊断记录：" + path,
                    "P4 自动合并", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static int RunApplication(string[] args)
    {
        string mode = GetMode(args);
        string request = Path.Combine(GetUserRoot(), "Updates", "Requests", Guid.NewGuid().ToString("N") + ".json");
        int result;
        using (Mutex lifetime = new Mutex(false, RunningMutex))
        {
            result = RunTool(PrepareRuntime(), mode, request);
        }
        if (result == UpdateExitCode && mode.Length == 0) return InstallUpdate(request);
        return result;
    }

    private static string GetMode(string[] args)
    {
        if (args.Length == 0) return String.Empty;
        if (args.Length == 1 && (args[0] == "-HeadlessTest" || args[0] == "-ReadOnlyStartupTest"))
            return args[0];
        throw new ArgumentException("不支持此启动参数。");
    }

    private static string GetUserRoot()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FlamesTools", "P4AutoMerge");
    }

    private static byte[] ReadResource(string name)
    {
        using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (resource == null) throw new InvalidDataException("缺少内置文件：" + name);
            using (MemoryStream bytes = new MemoryStream())
            {
                resource.CopyTo(bytes);
                return bytes.ToArray();
            }
        }
    }

    private static string GetDigest(byte[] bytes)
    {
        using (SHA256 hash = SHA256.Create())
            return BitConverter.ToString(hash.ComputeHash(bytes)).Replace("-", String.Empty);
    }

    private static string PrepareRuntime()
    {
        var resources = new System.Collections.Generic.Dictionary<string, byte[]>();
        StringBuilder digests = new StringBuilder();
        foreach (string name in RuntimeNames)
        {
            resources[name] = ReadResource(name);
            digests.Append(GetDigest(resources[name]));
        }
        string identity = GetDigest(Utf8.GetBytes(digests.ToString()));
        string root = Path.Combine(GetUserRoot(), "Runtime", identity);
        using (Mutex gate = new Mutex(false, "Local\\P4AutoMerge.Package." + identity))
        {
            bool held = false;
            try
            {
                try { held = gate.WaitOne(ExtractTimeoutMs); }
                catch (AbandonedMutexException) { held = true; }
                if (!held) throw new TimeoutException("其他窗口正在准备此版本，请稍后重新打开。");
                Directory.CreateDirectory(root);
                foreach (string name in RuntimeNames)
                    WriteResource(Path.Combine(root, name), resources[name]);
            }
            finally { if (held) gate.ReleaseMutex(); }
        }
        return root;
    }

    private static void WriteResource(string path, byte[] bytes)
    {
        if (File.Exists(path) && GetDigest(File.ReadAllBytes(path)) == GetDigest(bytes)) return;
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static ProcessStartInfo CreateStartInfo(string root, string mode, string request)
    {
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string shell = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(shell)) throw new FileNotFoundException("需要 Windows PowerShell 5.1。", shell);
        var info = new ProcessStartInfo
        {
            FileName = shell,
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" +
                Path.Combine(root, GuiName) + "\" " + mode,
            WorkingDirectory = root,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8
        };
        if (mode.Length == 0)
        {
            info.EnvironmentVariables["P4AM_UPDATE_REQUEST"] = request;
            info.EnvironmentVariables["P4AM_EXECUTABLE"] = Assembly.GetExecutingAssembly().Location;
        }
        else
        {
            info.EnvironmentVariables.Remove("P4AM_UPDATE_REQUEST");
            info.EnvironmentVariables.Remove("P4AM_EXECUTABLE");
        }
        return info;
    }

    private static int RunTool(string root, string mode, string request)
    {
        using (Process child = new Process())
        {
            child.StartInfo = CreateStartInfo(root, mode, request);
            if (!child.Start()) throw new IOException("无法启动工具界面。");
            var output = child.StandardOutput.ReadToEndAsync();
            var errors = child.StandardError.ReadToEndAsync();
            child.WaitForExit();
            string report = output.Result + errors.Result;
            if (mode.Length != 0)
            {
                WriteDiagnosticOutput(report + "Diagnostic log: " + SaveDiagnostic(report), false);
            }
            if (child.ExitCode != 0 && child.ExitCode != UpdateExitCode)
                throw new InvalidOperationException("工具退出码 " + child.ExitCode + "\n" + report);
            return child.ExitCode;
        }
    }

    private static int InstallUpdate(string request)
    {
        var data = new JavaScriptSerializer().Deserialize<System.Collections.Generic.Dictionary<string, string>>(
            File.ReadAllText(request, Utf8));
        string installer = Path.GetFullPath(data["Path"]);
        string allowed = Path.GetFullPath(Path.Combine(GetUserRoot(), "Updates", "Downloads")) + Path.DirectorySeparatorChar;
        if (!installer.StartsWith(allowed, StringComparison.OrdinalIgnoreCase) ||
            !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(installer), @"^P4AutoMerge-\d+\.\d+\.\d+-Setup-x64\.exe$"))
            throw new InvalidDataException("更新安装包路径无效。");
        if (!String.Equals(GetDigest(File.ReadAllBytes(installer)), data["SHA256"], StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("更新安装包校验失败，旧版本保留。");
        string directory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string arguments = "/SP- /NORESTART";
        if (File.Exists(Path.Combine(directory, "unins000.exe"))) arguments += " /DIR=\"" + directory + "\"";
        File.Delete(request);
        Process.Start(new ProcessStartInfo { FileName = installer, Arguments = arguments, UseShellExecute = true });
        return 0;
    }

    private static void WriteDiagnosticOutput(string text, bool error)
    {
        byte[] bytes = Utf8.GetBytes(text + Environment.NewLine);
        Stream output = error ? Console.OpenStandardError() : Console.OpenStandardOutput();
        output.Write(bytes, 0, bytes.Length);
        output.Flush();
    }

    private static string SaveDiagnostic(string text)
    {
        try
        {
            string directory = Path.Combine(GetUserRoot(), "Diagnostics");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "launcher-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") +
                "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".log");
            File.WriteAllText(path, text, Utf8);
            return path;
        }
        catch { return "无法写入诊断记录。"; }
    }
}
