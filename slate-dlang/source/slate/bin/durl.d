/// Command-line HTTP transfer utility built on slate.http.
///
/// Provides curl-compatible CLI ergonomics, dual-mode execution (standard vs @nogc),
/// HTTP/2 and HTTP/3 protocol selection, pooled parallel transfers, and verbose observability.
module slate.bin.durl;

import slate.http;

import std.stdio : File, write, writeln, writefln, stdout, stderr;
import std.getopt;
import std.string : strip, indexOf, toUpper;
import std.file : exists, remove;
import std.format : format;

/// Protocol tracing sink routing libcurl debug messages to stderr (@nogc nothrow).
nothrow @nogc
void durlVerboseSink(CurlInfoType type, const(char)[] data, void* userdata)
{
    import core.stdc.stdio : stderr, fputs, fwrite, fputc, fflush, FILE;
    FILE* fp = userdata !is null ? cast(FILE*) userdata : stderr;
    const(char)* prefix = null;
    switch (type)
    {
        case CurlInfoType.text:
            prefix = "* ";
            break;
        case CurlInfoType.headerOut:
            prefix = "> ";
            break;
        case CurlInfoType.headerIn:
            prefix = "< ";
            break;
        case CurlInfoType.sslDataIn:
        case CurlInfoType.sslDataOut:
            prefix = "* [SSL] ";
            break;
        default:
            return;
    }
    if (prefix !is null)
    {
        fputs(prefix, fp);
        fwrite(data.ptr, 1, data.length, fp);
        if (data.length > 0 && data[$ - 1] != '\n')
            fputc('\n', fp);
        fflush(fp);
    }
}

/// Helper to execute client perform in strict @nogc context using caller-provided buffer.
@nogc static Response performNogc(ref Client client, const ref Request req, ubyte[] buffer)
{
    return client.perform(req, buffer);
}

/// Outputs formatted HTTP response according to CLI flags.
void printResponse(ref const(Response) res, bool includeHeaders, bool isHead, string outputFile, File outStream = stdout)
{
    if (includeHeaders)
    {
        string verStr = "HTTP/1.1";
        switch (res.httpVersion)
        {
            case HttpVersion.h2:
            case HttpVersion.h2Tls:
            case HttpVersion.h2PriorKnowledge:
                verStr = "HTTP/2";
                break;
            case HttpVersion.h3:
            case HttpVersion.h3Only:
                verStr = "HTTP/3";
                break;
            default:
                verStr = "HTTP/1.1";
                break;
        }
        outStream.writefln("%s %d", verStr, res.status);
        foreach (ref h; res.headers)
            outStream.writefln("%s: %s", h.name, h.value);
        outStream.writeln();
        outStream.flush();
    }

    if (!isHead && res.bodyData.length > 0)
    {
        if (outputFile.length > 0)
        {
            import std.file : write;
            write(outputFile, res.bodyData);
        }
        else
        {
            outStream.rawWrite(res.bodyData);
            outStream.flush();
        }
    }
}

/// Prints CLI usage and help message.
void printHelp(File outStream = stdout)
{
    outStream.write(
`Usage: durl [options] <URL...>

Options:
  -V, --version              Print version and libcurl backend capabilities
  -h, --help                 Print this help message
  -X, --request <METHOD>     HTTP method (GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS)
  -d, --data <DATA>          HTTP request body data (defaults method to POST)
  -H, --header <HEADER>      Custom header in "Name: Value" format (repeatable)
  -i, --include              Include HTTP response status line and headers in output
  -I, --head                 Issue a HEAD request and show status and headers only
  -L, --location             Follow HTTP redirects
      --max-redirs <N>       Maximum number of redirects to follow (default: 5)
      --allow-downgrade      Allow redirect from HTTPS to HTTP
  -k, --insecure             Allow insecure TLS connections (skip certificate verification)
      --cacert <PATH>        Path to custom CA certificate bundle (PEM format)
      --altsvc <PATH>        Path to Alt-Svc cache file for HTTP/3 upgrades
      --http1.1              Use HTTP/1.1 strictly
      --http2                Use HTTP/2
      --http2-prior-knowledge Use cleartext HTTP/2 without Upgrade
      --http3                Use HTTP/3 (QUIC) with fallback
      --http3-only           Use HTTP/3 (QUIC) strictly without downgrade
  -m, --max-time <MS>        Maximum transfer time in milliseconds
      --connect-timeout <MS> Maximum connect timeout in milliseconds
  -o, --output <FILE>        Write response body to file instead of stdout
  -v, --verbose              Verbose protocol and TLS trace output to stderr
      --nogc                 Execute via zero-allocation @nogc stack buffer path
      --parallel             Execute multiple URLs concurrently in a single batch

Examples:
  durl https://example.com/
  durl -i -X POST -d '{"hello":"world"}' -H "Content-Type: application/json" https://httpbin.org/post
  durl -L -k https://localhost:8443/
  durl --parallel https://site1.com https://site2.com
  durl --nogc -o file.bin https://example.com/data
`);
    outStream.flush();
}

/// Core durl CLI command execution entry point.
int runDurl(string[] args, File outStream = stdout, File errStream = stderr)
{
    bool showVersion = false;
    bool showHelp = false;
    string requestMethod = null;
    string dataPayload = null;
    string[] headerArgs;
    bool includeHeaders = false;
    bool isHead = false;
    bool followRedirects = false;
    int maxRedirs = 5;
    bool allowDowngrade = false;
    bool insecure = false;
    string cacert = null;
    string altsvc = null;
    bool h11Flag = false;
    bool h2Flag = false;
    bool h2PriorFlag = false;
    bool h3Flag = false;
    bool h3OnlyFlag = false;
    long maxTimeMs = 0;
    long connectTimeoutMs = 0;
    string outputFile = null;
    bool verbose = false;
    bool nogc = false;
    bool parallel = false;

    try
    {
        auto helpInfo = getopt(
            args,
            std.getopt.config.caseSensitive,
            "V|version", &showVersion,
            "h|help", &showHelp,
            "X|request", &requestMethod,
            "d|data", &dataPayload,
            "H|header", &headerArgs,
            "i|include", &includeHeaders,
            "I|head", &isHead,
            "L|location", &followRedirects,
            "max-redirs", &maxRedirs,
            "allow-downgrade", &allowDowngrade,
            "k|insecure", &insecure,
            "cacert", &cacert,
            "altsvc", &altsvc,
            "http1.1", &h11Flag,
            "http2", &h2Flag,
            "http2-prior-knowledge", &h2PriorFlag,
            "http3", &h3Flag,
            "http3-only", &h3OnlyFlag,
            "m|max-time", &maxTimeMs,
            "connect-timeout", &connectTimeoutMs,
            "o|output", &outputFile,
            "v|verbose", &verbose,
            "nogc", &nogc,
            "parallel", &parallel,
        );

        if (showHelp || helpInfo.helpWanted)
        {
            printHelp(outStream);
            return 0;
        }

        if (showVersion)
        {
            outStream.writeln("durl 0.1.0 (slate.http)");
            outStream.write(describeBackend());
            if (!hasHttp3())
                outStream.writeln(http3UnavailableExplanation());
            outStream.flush();
            return 0;
        }

        if (args.length <= 1)
        {
            errStream.writeln("durl: no URL specified!");
            errStream.writeln("Try 'durl --help' for usage.");
            errStream.flush();
            return 2;
        }

        string[] urls = args[1 .. $];

        // Determine effective HTTP method
        Method method = Method.GET;
        if (isHead)
        {
            method = Method.HEAD;
            includeHeaders = true;
        }
        else if (requestMethod !is null)
        {
            switch (requestMethod.toUpper())
            {
                case "GET": method = Method.GET; break;
                case "POST": method = Method.POST; break;
                case "PUT": method = Method.PUT; break;
                case "DELETE": method = Method.DELETE; break;
                case "HEAD": method = Method.HEAD; break;
                case "PATCH": method = Method.PATCH; break;
                case "OPTIONS": method = Method.OPTIONS; break;
                default:
                    errStream.writefln("durl: unsupported HTTP method '%s'", requestMethod);
                    errStream.flush();
                    return 2;
            }
        }
        else if (dataPayload !is null)
        {
            method = Method.POST;
        }

        // Parse headers
        Header[] parsedHeaders;
        foreach (h; headerArgs)
        {
            auto idx = h.indexOf(':');
            if (idx < 0)
            {
                errStream.writefln("durl: invalid header format (expected 'Name: Value'): %s", h);
                errStream.flush();
                return 2;
            }
            string name = h[0 .. idx].strip();
            string val = h[idx + 1 .. $].strip();
            parsedHeaders ~= Header(name, val);
        }

        // Determine protocol version
        HttpVersion protoVersion = HttpVersion.auto_;
        if (h11Flag) protoVersion = HttpVersion.h1_1;
        else if (h2PriorFlag) protoVersion = HttpVersion.h2PriorKnowledge;
        else if (h2Flag) protoVersion = HttpVersion.h2;
        else if (h3Flag) protoVersion = HttpVersion.h3;
        else if (h3OnlyFlag) protoVersion = HttpVersion.h3Only;

        // Configure client options
        ClientConfig cfg;
        cfg.defaultHttpVersion = protoVersion;

        if (followRedirects)
        {
            cfg.redirects.mode = RedirectMode.follow;
            cfg.redirects.maxRedirects = maxRedirs;
            cfg.redirects.allowHttpsToHttpDowngrade = allowDowngrade;
        }

        if (insecure)
        {
            cfg.tlsMode = TlsMode.insecureOptIn;
            cfg.verifyPeer = false;
            cfg.verifyHost = false;
        }

        if (cacert !is null)
            cfg.caInfo = cacert;

        if (altsvc !is null)
            cfg.altSvcCachePath = altsvc;

        if (maxTimeMs > 0)
            cfg.timeouts.totalMs = maxTimeMs;

        if (connectTimeoutMs > 0)
            cfg.timeouts.connectMs = connectTimeoutMs;

        if (verbose)
        {
            cfg.verbose = true;
            cfg.debugSink = &durlVerboseSink;
            cfg.debugUserdata = cast(void*) errStream.getFP();
        }

        Request makeRequest(string url)
        {
            Request req = Request(url, method, protoVersion);
            if (dataPayload !is null)
                req = req.withBody(dataPayload);
            if (parsedHeaders.length > 0)
                req = req.withHeaders(parsedHeaders);
            if (connectTimeoutMs > 0 || maxTimeMs > 0)
                req = req.withTimeouts(connectTimeoutMs, maxTimeMs);
            return req;
        }

        if (parallel && urls.length > 1)
        {
            MultiConfig multiCfg;
            multiCfg.clientConfig = cfg;
            multiCfg.altSvcCachePath = cfg.altSvcCachePath;
            auto multi = MultiClient.create(multiCfg);

            Request[] reqs;
            foreach (u; urls)
                reqs ~= makeRequest(u);

            Response[] responses = multi.performAll(reqs);
            foreach (ref res; responses)
                printResponse(res, includeHeaders, isHead, outputFile, outStream);
        }
        else
        {
            auto client = Client.create(cfg);
            foreach (u; urls)
            {
                Request req = makeRequest(u);
                Response res;
                if (nogc)
                {
                    ubyte[65536] staticBuf;
                    res = performNogc(client, req, staticBuf[]);
                }
                else
                {
                    res = client.perform(req);
                }
                printResponse(res, includeHeaders, isHead, outputFile, outStream);
            }
        }

        return 0;
    }
    catch (GetOptException e)
    {
        errStream.writefln("durl: option error: %s", e.msg);
        errStream.writeln("Try 'durl --help' for usage.");
        errStream.flush();
        return 2;
    }
    catch (TimeoutException e)
    {
        errStream.writefln("durl: (%d) %s: %s", cast(int) e.code, curlCodeToString(e.code), e.msg);
        errStream.flush();
        return cast(int) e.code != 0 ? cast(int) e.code : 28;
    }
    catch (TooManyRedirectsException e)
    {
        errStream.writefln("durl: (%d) %s: %s", cast(int) e.code, curlCodeToString(e.code), e.msg);
        errStream.flush();
        return cast(int) e.code != 0 ? cast(int) e.code : 47;
    }
    catch (CancelledException e)
    {
        errStream.writefln("durl: request cancelled: %s", e.msg);
        errStream.flush();
        return 42;
    }
    catch (CurlException e)
    {
        errStream.writefln("durl: (%d) %s: %s", cast(int) e.code, curlCodeToString(e.code), e.msg);
        errStream.flush();
        return cast(int) e.code != 0 ? cast(int) e.code : 1;
    }
    catch (Exception e)
    {
        errStream.writefln("durl: error: %s", e.msg);
        errStream.flush();
        return 1;
    }
}

version (unittest)
{
    // Unittests run via DUB test runner
}
else
{
    int main(string[] args)
    {
        return runDurl(args);
    }
}

// --- Unit Tests for slate.bin.durl ---

// Spec: CLI argument parsing and error reporting validation
/// Example:
/// ---
/// import slate.bin.durl;
/// int rc = runDurl(["durl", "--help"]);
/// assert(rc == 0);
/// ---
unittest
{
    // Best practice: verify help, version, and option validation
    assert(runDurl(["durl", "--help"]) == 0);
    assert(runDurl(["durl", "-h"]) == 0);
    assert(runDurl(["durl", "--version"]) == 0);
    assert(runDurl(["durl", "-V"]) == 0);

    // Missing URL returns exit code 2
    assert(runDurl(["durl"]) == 2);

    // Invalid option returns exit code 2
    assert(runDurl(["durl", "--invalid-option-xyz"]) == 2);

    // Invalid header format returns exit code 2
    assert(runDurl(["durl", "-H", "BadHeaderWithoutColon", "http://127.0.0.1/"]) == 2);

    // Unsupported method returns exit code 2
    assert(runDurl(["durl", "-X", "NOTAMETHOD", "http://127.0.0.1/"]) == 2);
}
