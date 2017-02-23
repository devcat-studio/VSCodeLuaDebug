// Original work by:
/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

// Modified by:
/*---------------------------------------------------------------------------------------------
*  Copyright (c) NEXON Korea Corporation. All rights reserved.
*  Licensed under the MIT License. See License.txt in the project root for license information.
*--------------------------------------------------------------------------------------------*/

using GiderosPlayerRemote;
using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace VSCodeDebug
{
    public class DebugSession : ICDPListener, IDebuggeeListener, IRemoteControllerListener
    {
        public ICDPSender toVSCode;
        public IDebuggeeSender toDebuggee;
        Process process;
        RemoteController giderosRemoteController;
        string giderosStdoutBuffer = "";
        string workingDirectory;
        string sourceBasePath;
        Tuple<string, int> fakeBreakpointMode = null;
        string startCommand;
        int startSeq;
        bool jumpToGiderosErrorPosition = false;
        bool stopGiderosWhenDebuggerStops = false;

        public DebugSession()
        {
            Program.WaitingUI.SetLabelText(
                "Waiting for commands from Visual Studio Code...");
        }

        void ICDPListener.X_FromVSCode(string command, int seq, dynamic args, string reqText)
        {
            lock (this)
            {
                //MessageBox.OK(reqText);
                if (args == null) { args = new { }; }

                if (fakeBreakpointMode != null)
                {
                    if (command == "configurationDone")
                    {
                        SendResponse(command, seq, null);
                    }
                    else if (command == "threads")
                    {
                        SendResponse(command, seq, new ThreadsResponseBody(
                            new List<Thread>() { new Thread(999, "fake-thread") }));
                    }
                    else if (command == "stackTrace")
                    {
                        var src = new Source(Path.Combine(sourceBasePath, fakeBreakpointMode.Item1));
                        var f = new StackFrame(9999, "fake-frame", src, fakeBreakpointMode.Item2, 0);
                        SendResponse(command, seq, new StackTraceResponseBody(
                            new List<StackFrame>() { f }));
                    }
                    else if (command == "scopes")
                    {
                        SendResponse(command, seq, new ScopesResponseBody(
                            new List<Scope>()));

                        System.Threading.Thread.Sleep(1000);
                        toVSCode.SendMessage(new TerminatedEvent());
                    }
                    else
                    {
                        SendErrorResponse(command, seq, 999, "", new { });
                    }
                    return;
                }

                try
                {
                    switch (command)
                    {
                        case "initialize":
                            Initialize(command, seq, args);
                            break;

                        case "launch":
                            Launch(command, seq, args);
                            break;

                        case "attach":
                            Attach(command, seq, args);
                            break;

                        case "disconnect":
                            Disconnect(command, seq, args);
                            break;

                        case "next":
                        case "continue":
                        case "stepIn":
                        case "stepOut":
                        case "stackTrace":
                        case "scopes":
                        case "variables":
                        case "threads":
                        case "setBreakpoints":
                        case "configurationDone":
                        case "evaluate":
                        case "pause":
                            if (toDebuggee != null)
                            {
                                toDebuggee.Send(reqText);
                            }
                            break;

                        case "source":
                            SendErrorResponse(command, seq, 1020, "command not supported: " + command);
                            break;

                        default:
                            SendErrorResponse(command, seq, 1014, "unrecognized request: {_request}", new { _request = command });
                            break;
                    }
                }
                catch (Exception e)
                {
                    MessageBox.WTF(e.ToString());
                    SendErrorResponse(command, seq, 1104, "error while processing request '{_request}' (exception: {_exception})", new { _request = command, _exception = e.Message });
                    Environment.Exit(1);
                }
            }
        }

        void SendResponse(string command, int seq, dynamic body)
        {
            var response = new Response(command, seq);
            if (body != null)
            {
                response.SetBody(body);
            }
            toVSCode.SendMessage(response);
        }

        void SendErrorResponse(string command, int seq, int id, string format, dynamic arguments = null, bool user = true, bool telemetry = false)
        {
            var response = new Response(command, seq);
            var msg = new Message(id, format, arguments, user, telemetry);
            var message = Utilities.ExpandVariables(msg.format, msg.variables);
            response.SetErrorBody(message, new ErrorResponseBody(msg));
            toVSCode.SendMessage(response);
        }

        void Disconnect(string command, int seq, dynamic arguments)
        {
            if (giderosRemoteController != null &&
                stopGiderosWhenDebuggerStops)
            {
                giderosRemoteController.SendStop();
            }

            if (process != null)
            {
                try
                {
                    process.Kill();
                }
                catch(Exception)
                {
                    // 정상 종료하면 이쪽 경로로 들어온다.
                }
                process = null;
            }

            SendResponse(command, seq, null);
            toVSCode.Stop();
        }

        void Initialize(string command, int seq, dynamic args)
        {
            SendResponse(command, seq, new Capabilities()
            {
                supportsConfigurationDoneRequest = true,
                supportsFunctionBreakpoints = false,
                supportsConditionalBreakpoints = false,
                supportsEvaluateForHovers = false,
                exceptionBreakpointFilters = new dynamic[0]
            });
        }

        void Launch(string command, int seq, dynamic args)
        {
            // 런치 전에 디버기가 접속할 수 있게 포트를 먼저 열어야 한다.
            var listener = PrepareForDebuggee(command, seq, args);

            string gprojPath = args.gprojPath;
            if (gprojPath == null)
            {
                //--------------------------------
                // validate argument 'executable'
                var runtimeExecutable = (string)args.executable;
                if (runtimeExecutable == null) { runtimeExecutable = ""; }

                runtimeExecutable = runtimeExecutable.Trim();
                if (runtimeExecutable.Length == 0)
                {
                    SendErrorResponse(command, seq, 3005, "Property 'executable' is empty.");
                    return;
                }
                if (!File.Exists(runtimeExecutable))
                {
                    SendErrorResponse(command, seq, 3006, "Runtime executable '{path}' does not exist.", new { path = runtimeExecutable });
                    return;
                }

                //--------------------------------
                if (!ReadBasicConfiguration(command, seq, args)) { return; }

                //--------------------------------
                var arguments = (string)args.arguments;
                if (arguments == null) { arguments = ""; }

                // validate argument 'env'
                Dictionary<string, string> env = null;
                var environmentVariables = args.env;
                if (environmentVariables != null)
                {
                    env = new Dictionary<string, string>();
                    foreach (var entry in environmentVariables)
                    {
                        env.Add((string)entry.Name, entry.Value.ToString());
                    }
                    if (env.Count == 0)
                    {
                        env = null;
                    }
                }

                process = new Process();
                process.StartInfo.CreateNoWindow = false;
                process.StartInfo.WindowStyle = ProcessWindowStyle.Normal;
                process.StartInfo.UseShellExecute = true;
                process.StartInfo.WorkingDirectory = workingDirectory;
                process.StartInfo.FileName = runtimeExecutable;
                process.StartInfo.Arguments = arguments;

                process.EnableRaisingEvents = true;
                process.Exited += (object sender, EventArgs e) =>
                {
                    lock (this)
                    {
                        toVSCode.SendMessage(new TerminatedEvent());
                    }
                };

                if (env != null)
                {
                    foreach (var entry in env)
                    {
                        System.Environment.SetEnvironmentVariable(entry.Key, entry.Value);
                    }
                }

                var cmd = string.Format("{0} {1}\n", runtimeExecutable, arguments);
                toVSCode.SendOutput("console", cmd);

                try
                {
                    process.Start();
                }
                catch (Exception e)
                {
                    SendErrorResponse(command, seq, 3012, "Can't launch terminal ({reason}).", new { reason = e.Message });
                    return;
                }
            }
            else
            {
                giderosRemoteController = new RemoteController();

                var connectStartedAt = DateTime.Now;
                bool alreadyLaunched = false;
                while (!giderosRemoteController.TryStart("127.0.0.1", 15000, gprojPath, this))
                {
                    if (DateTime.Now - connectStartedAt > TimeSpan.FromSeconds(10))
                    {
                        SendErrorResponse(command, seq, 3012, "Can't connect to GiderosPlayer.", new { });
                        return;
                    }
                    else if (alreadyLaunched)
                    {
                        System.Threading.Thread.Sleep(100);
                    }
                    else
                    {
                        try
                        {
                            var giderosPath = (string)args.giderosPath;
                            process = new Process();
                            process.StartInfo.UseShellExecute = true;
                            process.StartInfo.CreateNoWindow = true;
                            process.StartInfo.WindowStyle = ProcessWindowStyle.Hidden;
                            process.StartInfo.WorkingDirectory = giderosPath;

                            // I don't know why this fix keeps GiderosPlayer.exe running
                            // after DebugAdapter stops.
                            // And I don't want to know..
                            process.StartInfo.FileName = "cmd.exe";
                            process.StartInfo.Arguments = "/c \"start GiderosPlayer.exe\"";
                            process.Start();

                            Program.WaitingUI.SetLabelText(
                                "Launching " + process.StartInfo.FileName + " " +
                                process.StartInfo.Arguments + "...");
                        }
                        catch (Exception e)
                        {
                            SendErrorResponse(command, seq, 3012, "Can't launch GiderosPlayer ({reason}).", new { reason = e.Message });
                            return;
                        }
                        alreadyLaunched = true;
                    }
                }

                new System.Threading.Thread(giderosRemoteController.ReadLoop).Start();
            }

            AcceptDebuggee(command, seq, args, listener);
        }

        void Attach(string command, int seq, dynamic args)
        {
            var listener = PrepareForDebuggee(command, seq, args);
            AcceptDebuggee(command, seq, args, listener);
        }

        TcpListener PrepareForDebuggee(string command, int seq, dynamic args)
        {
            IPAddress listenAddr = (bool)args.listenPublicly
                ? IPAddress.Any
                : IPAddress.Parse("127.0.0.1");
            int port = (int)args.listenPort;

            TcpListener listener = new TcpListener(listenAddr, port);
            listener.Start();
            return listener;
        }

        void AcceptDebuggee(string command, int seq, dynamic args, TcpListener listener)
        {
            if (!ReadBasicConfiguration(command, seq, args)) { return; }

            var encodingName = (string)args.encoding;
            Encoding encoding;
            if (encodingName != null)
            {
                int codepage;
                if (int.TryParse(encodingName, out codepage))
                {
                    encoding = Encoding.GetEncoding(codepage);
                }
                else
                {
                    encoding = Encoding.GetEncoding(encodingName);
                }
            }
            else
            {
                encoding = Encoding.UTF8;
            }

            Program.WaitingUI.SetLabelText(
                "Waiting for debugee at TCP " +
                listener.LocalEndpoint.ToString() + "...");

            var ncom = new DebuggeeProtocol(
                this,
                listener,
                encoding);
            this.startCommand = command;
            this.startSeq = seq;
            ncom.StartThread();
        }

        bool ReadBasicConfiguration(string command, int seq, dynamic args)
        {
            workingDirectory = (string)args.workingDirectory;
            if (workingDirectory == null) { workingDirectory = ""; }

            workingDirectory = workingDirectory.Trim();
            if (workingDirectory.Length == 0)
            {
                SendErrorResponse(command, seq, 3003, "Property 'workingDirectory' is empty.");
                return false;
            }
            if (!Directory.Exists(workingDirectory))
            {
                SendErrorResponse(command, seq, 3004, "Working directory '{path}' does not exist.", new { path = workingDirectory });
                return false;
            }

            if (args.jumpToGiderosErrorPosition != null &&
                (bool)args.jumpToGiderosErrorPosition == true)
            {
                jumpToGiderosErrorPosition = true;
            }

            if (args.stopGiderosWhenDebuggerStops != null &&
                (bool)args.stopGiderosWhenDebuggerStops == true)
            {
                stopGiderosWhenDebuggerStops = true;
            }

            if (args.sourceBasePath != null)
            {
                sourceBasePath = (string)args.sourceBasePath;
            }
            else
            {
                sourceBasePath = workingDirectory;
            }

            return true;
        }

        void IDebuggeeListener.X_DebuggeeArrived(IDebuggeeSender toDebuggee)
        {
            lock (this)
            {
                if (fakeBreakpointMode != null) { return; }
                this.toDebuggee = toDebuggee;
                Program.WaitingUI.Hide();
                var welcome = new
                {
                    command = "welcome",
                    sourceBasePath = sourceBasePath
                };
                toDebuggee.Send(JsonConvert.SerializeObject(welcome));

                SendResponse(startCommand, startSeq, null);
                toVSCode.SendMessage(new InitializedEvent());
                startCommand = null;
            }
        }

        void IDebuggeeListener.X_FromDebuggee(byte[] json)
        {
            lock (this)
            {
                if (fakeBreakpointMode != null) { return; }
                toVSCode.SendJSONEncodedMessage(json);
            }
        }

        void IDebuggeeListener.X_DebuggeeHasGone()
        {
            System.Threading.Thread.Sleep(500);
            lock (this)
            {
                if (fakeBreakpointMode != null) { return; }
                toVSCode.SendMessage(new TerminatedEvent());
            }
        }

        void IRemoteControllerListener.X_Log(LogType logType, string content)
        {
            lock (this)
            {
                switch (logType)
                {
                    case LogType.Info:
                        toVSCode.SendOutput("console", content);
                        break;

                    case LogType.PlayerOutput:
                        CheckGiderosOutput(content);

                        // Gideros sends '\n' as seperate packet,
                        // and VS Code adds linefeed to the end of each output message.
                        if (content == "\n")
                        {
                            bool looksLikeGiderosError = errorMatcher.Match(giderosStdoutBuffer).Success;
                            toVSCode.SendOutput(
                                (looksLikeGiderosError ? "stderr" : "stdout"),
                                giderosStdoutBuffer);
                            giderosStdoutBuffer = "";
                        }
                        else
                        {
                            giderosStdoutBuffer += content;
                        }
                        break;

                    case LogType.Warning:
                        toVSCode.SendOutput("stderr", content);
                        break;
                }
            }
        }

        protected static readonly Regex errorMatcher = new Regex(@"^([^:\n\r]+):(\d+): ");
        void CheckGiderosOutput(string content)
        {
            Match m = errorMatcher.Match(content);
            if (!m.Success) { return; }

            if (jumpToGiderosErrorPosition)
            {
                // Entering fake breakpoint mode:
                string file = m.Groups[1].ToString();
                int line = int.Parse(m.Groups[2].ToString());
                this.fakeBreakpointMode = new Tuple<string, int>(file, line);

                if (startCommand != null)
                {
                    SendResponse(startCommand, startSeq, null);
                    toVSCode.SendMessage(new InitializedEvent());
                    startCommand = null;
                }
                toVSCode.SendMessage(new StoppedEvent(999, "error"));
            }
        }
    }
}
