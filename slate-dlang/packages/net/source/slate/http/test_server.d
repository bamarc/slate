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
                    import std.string : indexOf;

                    auto spaceIdx = reqStr.indexOf(' ');
                    if (spaceIdx > 0)
                    {
                        lastMethod = reqStr[0 .. spaceIdx];
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
                    string resp = format(
                            "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: text/plain\r\n%s\r\n%s",
                            responsePayload.length, connHeader, responsePayload);
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
