module slate.http.test_server;

import std.socket;
import core.thread;
import core.atomic : atomicLoad, atomicStore, atomicOp;

/// Lightweight local HTTP/1.1 test server stub binding to an ephemeral OS loopback port.
package class HttpStubServer
{
    TcpSocket listener;
    ushort port;
    Thread thread;
    string responsePayload;
    shared bool running = true;
    string lastMethod;
    string lastRawRequest;
    shared int requestCount;
    bool keepAlive;
    int delayMs;
    /// Status code sent for every request (default 200).
    int statusCode = 200;
    /// When non-zero, every request whose path is not `/final` is answered with this redirect
    /// status and `Location: /final`.
    int redirectStatus;
    /// `Location` of the redirect (default `/final`, which is also what ends the chain).
    string redirectLocation = "/final";
    /// Where `/hop0` redirects to (empty: `/hop0` is answered normally).
    string hopFinalLocation;
    /// Body sent with the redirect response (default empty).
    string redirectBody;
    /// Redirect every request, including `/final` (an endless chain).
    bool redirectAlways;
    /// Request lines (`METHOD /path`) in arrival order.
    string[] requestLines;
    /// Complete request heads in arrival order.
    string[] rawRequests;

    this(string responsePayload = "Hello from Slate HTTP!", bool keepAlive = false, int delayMs = 0)
    {
        this.responsePayload = responsePayload;
        this.keepAlive = keepAlive;
        this.delayMs = delayMs;
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress("127.0.0.1", 0));
        listener.listen(8);
        port = (cast(InternetAddress) listener.localAddress).port;

        thread = new Thread(&run);
        thread.start();
    }

    void run()
    {
        import core.time : dur;

        while (atomicLoad(running))
        {
            try
            {
                Socket client = listener.accept();
                if (!atomicLoad(running))
                {
                    client.close();
                    break;
                }
                scope (exit)
                    client.close();
                client.setOption(SocketOptionLevel.SOCKET,
                        SocketOption.RCVTIMEO, dur!"seconds"(3));

                while (atomicLoad(running))
                {
                    char[4096] reqBuf;
                    auto n = client.receive(reqBuf[]);
                    if (n <= 0)
                        break;

                    string reqStr = reqBuf[0 .. n].idup;
                    lastRawRequest = reqStr;
                    import std.string : indexOf, split;

                    auto spaceIdx = reqStr.indexOf(' ');
                    if (spaceIdx > 0)
                    {
                        lastMethod = reqStr[0 .. spaceIdx];
                    }
                    string path = "/";
                    {
                        auto lineEnd = reqStr.indexOf("\r\n");
                        auto line = lineEnd > 0 ? reqStr[0 .. lineEnd] : reqStr;
                        auto parts = line.split(' ');
                        if (parts.length >= 2)
                            path = parts[1];
                        synchronized (this)
                        {
                            requestLines ~= parts.length >= 2 ? parts[0] ~ " " ~ parts[1] : line;
                            rawRequests ~= reqStr;
                        }
                    }
                    atomicOp!"+="(requestCount, 1);

                    if (delayMs > 0)
                    {
                        import core.thread : Thread, msecs;

                        Thread.sleep(msecs(delayMs));
                    }

                    import std.format : format;

                    string connHeader = keepAlive ? "Connection: keep-alive\r\n"
                        : "Connection: close\r\n";
                    string resp;
                    // `/hop<N>` redirects to `/hop<N-1>`; `/hop0` is answered normally.
                    string location = redirectLocation;
                    bool redirect = redirectStatus != 0 && (redirectAlways || path != "/final");
                    if (redirectStatus != 0 && path.length > 4 && path[0 .. 4] == "/hop")
                    {
                        import std.conv : to;

                        const hopN = path[4 .. $].to!int;
                        redirect = hopN > 0 || hopFinalLocation.length > 0;
                        location = hopN > 0 ? format("/hop%d", hopN - 1) : hopFinalLocation;
                    }
                    if (redirect)
                        resp = format("HTTP/1.1 %d Redirect\r\nLocation: %s\r\nContent-Length: %d\r\n%s\r\n%s",
                                redirectStatus, location, redirectBody.length,
                                connHeader, redirectBody);
                    else
                        resp = format(
                                "HTTP/1.1 %d Status\r\nContent-Length: %d\r\nContent-Type: text/plain\r\n%s\r\n%s",
                                statusCode, responsePayload.length, connHeader, responsePayload);
                    client.send(resp);

                    if (!keepAlive)
                        break;
                }
            }
            catch (Exception)
            {
                break;
            }
        }
    }

    void close()
    {
        atomicStore(running, false);
        try
        {
            auto s = new TcpSocket();
            s.connect(new InternetAddress("127.0.0.1", port));
            s.close();
        }
        catch (Exception)
        {
        }
        try
        {
            listener.close();
        }
        catch (Exception)
        {
        }
        if (thread !is null)
        {
            thread.join();
        }
    }
}
