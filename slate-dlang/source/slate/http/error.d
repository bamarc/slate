/// Error types, status codes, and exception hierarchy for libcurl transfers.
///
/// This module provides the `CurlCode` enum, the `CurlException` and
/// `HttpStatusException` classes, pure `@nogc` code-to-string mappings, and
/// preallocated exception throw paths for `@nogc` execution contexts.
module slate.http.error;

import slate.http.c_bind;

/// Strongly-typed curl return codes, directly corresponding to libcurl's `CURLcode`.
enum CurlCode : int
{
    CURLE_OK                        = 0,
    CURLE_UNSUPPORTED_PROTOCOL      = 1,
    CURLE_FAILED_INIT               = 2,
    CURLE_URL_MALFORMAT             = 3,
    CURLE_NOT_BUILT_IN              = 4,
    CURLE_COULDNT_RESOLVE_PROXY     = 5,
    CURLE_COULDNT_RESOLVE_HOST      = 6,
    CURLE_COULDNT_CONNECT           = 7,
    CURLE_WEIRD_SERVER_REPLY        = 8,
    CURLE_REMOTE_ACCESS_DENIED      = 9,
    CURLE_FTP_ACCEPT_FAILED         = 10,
    CURLE_FTP_WEIRD_PASS_REPLY      = 11,
    CURLE_FTP_ACCEPT_TIMEOUT        = 12,
    CURLE_FTP_WEIRD_PASV_REPLY      = 13,
    CURLE_FTP_WEIRD_227_FORMAT      = 14,
    CURLE_FTP_CANT_GET_HOST         = 15,
    CURLE_HTTP2                     = 16,
    CURLE_FTP_COULDNT_SET_TYPE      = 17,
    CURLE_PARTIAL_FILE              = 18,
    CURLE_FTP_COULDNT_RETR_FILE     = 19,
    CURLE_QUOTE_ERROR               = 21,
    CURLE_HTTP_RETURNED_ERROR       = 22,
    CURLE_WRITE_ERROR               = 23,
    CURLE_UPLOAD_FAILED             = 25,
    CURLE_READ_ERROR                = 26,
    CURLE_OUT_OF_MEMORY             = 27,
    CURLE_OPERATION_TIMEDOUT        = 28,
    CURLE_FTP_PORT_FAILED           = 30,
    CURLE_FTP_COULDNT_USE_REST      = 31,
    CURLE_RANGE_ERROR               = 33,
    CURLE_HTTP_POST_ERROR           = 34,
    CURLE_SSL_CONNECT_ERROR         = 35,
    CURLE_BAD_DOWNLOAD_RESUME       = 36,
    CURLE_FILE_COULDNT_READ_FILE    = 37,
    CURLE_LDAP_CANNOT_BIND          = 38,
    CURLE_LDAP_SEARCH_FAILED        = 39,
    CURLE_FUNCTION_NOT_FOUND        = 41,
    CURLE_ABORTED_BY_CALLBACK       = 42,
    CURLE_BAD_FUNCTION_ARGUMENT     = 43,
    CURLE_INTERFACE_FAILED          = 45,
    CURLE_TOO_MANY_REDIRECTS        = 47,
    CURLE_UNKNOWN_OPTION            = 48,
    CURLE_SETOPT_OPTION_SYNTAX      = 49,
    CURLE_GOT_NOTHING               = 52,
    CURLE_SSL_ENGINE_NOTFOUND       = 53,
    CURLE_SSL_ENGINE_SETFAILED      = 54,
    CURLE_SEND_ERROR                = 55,
    CURLE_RECV_ERROR                = 56,
    CURLE_SSL_CERTPROBLEM           = 58,
    CURLE_SSL_CIPHER                = 59,
    CURLE_PEER_FAILED_VERIFICATION  = 60,
    CURLE_BAD_CONTENT_ENCODING      = 61,
    CURLE_FILESIZE_EXCEEDED         = 63,
    CURLE_USE_SSL_FAILED            = 64,
    CURLE_SEND_FAIL_REWIND          = 65,
    CURLE_SSL_ENGINE_INITFAILED     = 66,
    CURLE_LOGIN_DENIED              = 67,
    CURLE_TFTP_NOTFOUND             = 68,
    CURLE_TFTP_PERM                 = 69,
    CURLE_REMOTE_DISK_FULL          = 70,
    CURLE_TFTP_ILLEGAL              = 71,
    CURLE_TFTP_UNKNOWNID            = 72,
    CURLE_REMOTE_FILE_EXISTS        = 73,
    CURLE_TFTP_NOSUCHUSER           = 74,
    CURLE_SSL_CACERT                = 77,
    CURLE_REMOTE_FILE_NOT_FOUND     = 78,
    CURLE_SSH                       = 79,
    CURLE_SSL_SHUTDOWN_FAILED       = 80,
    CURLE_AGAIN                     = 81,
    CURLE_SSL_CRL_BADFILE           = 82,
    CURLE_SSL_ISSUER_ERROR          = 83,
    CURLE_FTP_PRET_FAILED           = 84,
    CURLE_RTSP_CSEQ_ERROR           = 85,
    CURLE_RTSP_SESSION_ERROR        = 86,
    CURLE_FTP_BAD_FILE_LIST         = 87,
    CURLE_CHUNK_FAILED              = 88,
    CURLE_NO_CONNECTION_AVAILABLE   = 89,
    CURLE_SSL_PINNEDPUBKEYNOTMATCH  = 90,
    CURLE_SSL_INVALIDCERTSTATUS     = 91,
    CURLE_HTTP2_STREAM              = 92,
    CURLE_RECURSIVE_API_CALL        = 93,
    CURLE_AUTH_ERROR                = 94,
    CURLE_HTTP3                     = 95,
    CURLE_QUIC_CONNECT_ERROR        = 96,
    CURLE_PROXY                     = 97,
    CURLE_SSL_CLIENTCERT            = 98,
    CURLE_UNRECOVERABLE_POLL        = 99,
    CURLE_TOO_LARGE                 = 100,
    CURLE_ECH_REQUIRED              = 101,
}

/// Returns the symbolic identifier name of a `CurlCode` in pure `@safe @nogc nothrow`.
pure @safe @nogc nothrow string curlCodeToString(CurlCode code)
{
    switch (code)
    {
        case CurlCode.CURLE_OK: return "CURLE_OK";
        case CurlCode.CURLE_UNSUPPORTED_PROTOCOL: return "CURLE_UNSUPPORTED_PROTOCOL";
        case CurlCode.CURLE_FAILED_INIT: return "CURLE_FAILED_INIT";
        case CurlCode.CURLE_URL_MALFORMAT: return "CURLE_URL_MALFORMAT";
        case CurlCode.CURLE_NOT_BUILT_IN: return "CURLE_NOT_BUILT_IN";
        case CurlCode.CURLE_COULDNT_RESOLVE_PROXY: return "CURLE_COULDNT_RESOLVE_PROXY";
        case CurlCode.CURLE_COULDNT_RESOLVE_HOST: return "CURLE_COULDNT_RESOLVE_HOST";
        case CurlCode.CURLE_COULDNT_CONNECT: return "CURLE_COULDNT_CONNECT";
        case CurlCode.CURLE_WEIRD_SERVER_REPLY: return "CURLE_WEIRD_SERVER_REPLY";
        case CurlCode.CURLE_REMOTE_ACCESS_DENIED: return "CURLE_REMOTE_ACCESS_DENIED";
        case CurlCode.CURLE_FTP_ACCEPT_FAILED: return "CURLE_FTP_ACCEPT_FAILED";
        case CurlCode.CURLE_FTP_WEIRD_PASS_REPLY: return "CURLE_FTP_WEIRD_PASS_REPLY";
        case CurlCode.CURLE_FTP_ACCEPT_TIMEOUT: return "CURLE_FTP_ACCEPT_TIMEOUT";
        case CurlCode.CURLE_FTP_WEIRD_PASV_REPLY: return "CURLE_FTP_WEIRD_PASV_REPLY";
        case CurlCode.CURLE_FTP_WEIRD_227_FORMAT: return "CURLE_FTP_WEIRD_227_FORMAT";
        case CurlCode.CURLE_FTP_CANT_GET_HOST: return "CURLE_FTP_CANT_GET_HOST";
        case CurlCode.CURLE_HTTP2: return "CURLE_HTTP2";
        case CurlCode.CURLE_FTP_COULDNT_SET_TYPE: return "CURLE_FTP_COULDNT_SET_TYPE";
        case CurlCode.CURLE_PARTIAL_FILE: return "CURLE_PARTIAL_FILE";
        case CurlCode.CURLE_FTP_COULDNT_RETR_FILE: return "CURLE_FTP_COULDNT_RETR_FILE";
        case CurlCode.CURLE_QUOTE_ERROR: return "CURLE_QUOTE_ERROR";
        case CurlCode.CURLE_HTTP_RETURNED_ERROR: return "CURLE_HTTP_RETURNED_ERROR";
        case CurlCode.CURLE_WRITE_ERROR: return "CURLE_WRITE_ERROR";
        case CurlCode.CURLE_UPLOAD_FAILED: return "CURLE_UPLOAD_FAILED";
        case CurlCode.CURLE_READ_ERROR: return "CURLE_READ_ERROR";
        case CurlCode.CURLE_OUT_OF_MEMORY: return "CURLE_OUT_OF_MEMORY";
        case CurlCode.CURLE_OPERATION_TIMEDOUT: return "CURLE_OPERATION_TIMEDOUT";
        case CurlCode.CURLE_FTP_PORT_FAILED: return "CURLE_FTP_PORT_FAILED";
        case CurlCode.CURLE_FTP_COULDNT_USE_REST: return "CURLE_FTP_COULDNT_USE_REST";
        case CurlCode.CURLE_RANGE_ERROR: return "CURLE_RANGE_ERROR";
        case CurlCode.CURLE_HTTP_POST_ERROR: return "CURLE_HTTP_POST_ERROR";
        case CurlCode.CURLE_SSL_CONNECT_ERROR: return "CURLE_SSL_CONNECT_ERROR";
        case CurlCode.CURLE_BAD_DOWNLOAD_RESUME: return "CURLE_BAD_DOWNLOAD_RESUME";
        case CurlCode.CURLE_FILE_COULDNT_READ_FILE: return "CURLE_FILE_COULDNT_READ_FILE";
        case CurlCode.CURLE_LDAP_CANNOT_BIND: return "CURLE_LDAP_CANNOT_BIND";
        case CurlCode.CURLE_LDAP_SEARCH_FAILED: return "CURLE_LDAP_SEARCH_FAILED";
        case CurlCode.CURLE_FUNCTION_NOT_FOUND: return "CURLE_FUNCTION_NOT_FOUND";
        case CurlCode.CURLE_ABORTED_BY_CALLBACK: return "CURLE_ABORTED_BY_CALLBACK";
        case CurlCode.CURLE_BAD_FUNCTION_ARGUMENT: return "CURLE_BAD_FUNCTION_ARGUMENT";
        case CurlCode.CURLE_INTERFACE_FAILED: return "CURLE_INTERFACE_FAILED";
        case CurlCode.CURLE_TOO_MANY_REDIRECTS: return "CURLE_TOO_MANY_REDIRECTS";
        case CurlCode.CURLE_UNKNOWN_OPTION: return "CURLE_UNKNOWN_OPTION";
        case CurlCode.CURLE_SETOPT_OPTION_SYNTAX: return "CURLE_SETOPT_OPTION_SYNTAX";
        case CurlCode.CURLE_GOT_NOTHING: return "CURLE_GOT_NOTHING";
        case CurlCode.CURLE_SSL_ENGINE_NOTFOUND: return "CURLE_SSL_ENGINE_NOTFOUND";
        case CurlCode.CURLE_SSL_ENGINE_SETFAILED: return "CURLE_SSL_ENGINE_SETFAILED";
        case CurlCode.CURLE_SEND_ERROR: return "CURLE_SEND_ERROR";
        case CurlCode.CURLE_RECV_ERROR: return "CURLE_RECV_ERROR";
        case CurlCode.CURLE_SSL_CERTPROBLEM: return "CURLE_SSL_CERTPROBLEM";
        case CurlCode.CURLE_SSL_CIPHER: return "CURLE_SSL_CIPHER";
        case CurlCode.CURLE_PEER_FAILED_VERIFICATION: return "CURLE_PEER_FAILED_VERIFICATION";
        case CurlCode.CURLE_BAD_CONTENT_ENCODING: return "CURLE_BAD_CONTENT_ENCODING";
        case CurlCode.CURLE_FILESIZE_EXCEEDED: return "CURLE_FILESIZE_EXCEEDED";
        case CurlCode.CURLE_USE_SSL_FAILED: return "CURLE_USE_SSL_FAILED";
        case CurlCode.CURLE_SEND_FAIL_REWIND: return "CURLE_SEND_FAIL_REWIND";
        case CurlCode.CURLE_SSL_ENGINE_INITFAILED: return "CURLE_SSL_ENGINE_INITFAILED";
        case CurlCode.CURLE_LOGIN_DENIED: return "CURLE_LOGIN_DENIED";
        case CurlCode.CURLE_TFTP_NOTFOUND: return "CURLE_TFTP_NOTFOUND";
        case CurlCode.CURLE_TFTP_PERM: return "CURLE_TFTP_PERM";
        case CurlCode.CURLE_REMOTE_DISK_FULL: return "CURLE_REMOTE_DISK_FULL";
        case CurlCode.CURLE_TFTP_ILLEGAL: return "CURLE_TFTP_ILLEGAL";
        case CurlCode.CURLE_TFTP_UNKNOWNID: return "CURLE_TFTP_UNKNOWNID";
        case CurlCode.CURLE_REMOTE_FILE_EXISTS: return "CURLE_REMOTE_FILE_EXISTS";
        case CurlCode.CURLE_TFTP_NOSUCHUSER: return "CURLE_TFTP_NOSUCHUSER";
        case CurlCode.CURLE_SSL_CACERT: return "CURLE_SSL_CACERT";
        case CurlCode.CURLE_REMOTE_FILE_NOT_FOUND: return "CURLE_REMOTE_FILE_NOT_FOUND";
        case CurlCode.CURLE_SSH: return "CURLE_SSH";
        case CurlCode.CURLE_SSL_SHUTDOWN_FAILED: return "CURLE_SSL_SHUTDOWN_FAILED";
        case CurlCode.CURLE_AGAIN: return "CURLE_AGAIN";
        case CurlCode.CURLE_SSL_CRL_BADFILE: return "CURLE_SSL_CRL_BADFILE";
        case CurlCode.CURLE_SSL_ISSUER_ERROR: return "CURLE_SSL_ISSUER_ERROR";
        case CurlCode.CURLE_FTP_PRET_FAILED: return "CURLE_FTP_PRET_FAILED";
        case CurlCode.CURLE_RTSP_CSEQ_ERROR: return "CURLE_RTSP_CSEQ_ERROR";
        case CurlCode.CURLE_RTSP_SESSION_ERROR: return "CURLE_RTSP_SESSION_ERROR";
        case CurlCode.CURLE_FTP_BAD_FILE_LIST: return "CURLE_FTP_BAD_FILE_LIST";
        case CurlCode.CURLE_CHUNK_FAILED: return "CURLE_CHUNK_FAILED";
        case CurlCode.CURLE_NO_CONNECTION_AVAILABLE: return "CURLE_NO_CONNECTION_AVAILABLE";
        case CurlCode.CURLE_SSL_PINNEDPUBKEYNOTMATCH: return "CURLE_SSL_PINNEDPUBKEYNOTMATCH";
        case CurlCode.CURLE_SSL_INVALIDCERTSTATUS: return "CURLE_SSL_INVALIDCERTSTATUS";
        case CurlCode.CURLE_HTTP2_STREAM: return "CURLE_HTTP2_STREAM";
        case CurlCode.CURLE_RECURSIVE_API_CALL: return "CURLE_RECURSIVE_API_CALL";
        case CurlCode.CURLE_AUTH_ERROR: return "CURLE_AUTH_ERROR";
        case CurlCode.CURLE_HTTP3: return "CURLE_HTTP3";
        case CurlCode.CURLE_QUIC_CONNECT_ERROR: return "CURLE_QUIC_CONNECT_ERROR";
        case CurlCode.CURLE_PROXY: return "CURLE_PROXY";
        case CurlCode.CURLE_SSL_CLIENTCERT: return "CURLE_SSL_CLIENTCERT";
        case CurlCode.CURLE_UNRECOVERABLE_POLL: return "CURLE_UNRECOVERABLE_POLL";
        case CurlCode.CURLE_TOO_LARGE: return "CURLE_TOO_LARGE";
        case CurlCode.CURLE_ECH_REQUIRED: return "CURLE_ECH_REQUIRED";
        default: return "CURLE_UNKNOWN";
    }
}

/// Returns a human-readable English description of a `CurlCode` in pure `@safe @nogc nothrow`.
pure @safe @nogc nothrow string curlCodeDescription(CurlCode code)
{
    switch (code)
    {
        case CurlCode.CURLE_OK: return "No error";
        case CurlCode.CURLE_UNSUPPORTED_PROTOCOL: return "Unsupported protocol";
        case CurlCode.CURLE_FAILED_INIT: return "Failed initialization";
        case CurlCode.CURLE_URL_MALFORMAT: return "URL using bad/illegal format or missing URL";
        case CurlCode.CURLE_NOT_BUILT_IN: return "Feature not built-in";
        case CurlCode.CURLE_COULDNT_RESOLVE_PROXY: return "Couldn't resolve proxy name";
        case CurlCode.CURLE_COULDNT_RESOLVE_HOST: return "Couldn't resolve host name";
        case CurlCode.CURLE_COULDNT_CONNECT: return "Failed to connect to host or proxy";
        case CurlCode.CURLE_WEIRD_SERVER_REPLY: return "Weird server reply";
        case CurlCode.CURLE_REMOTE_ACCESS_DENIED: return "Remote access denied";
        case CurlCode.CURLE_FTP_ACCEPT_FAILED: return "FTP accept failed";
        case CurlCode.CURLE_FTP_WEIRD_PASS_REPLY: return "FTP weird PASS reply";
        case CurlCode.CURLE_FTP_ACCEPT_TIMEOUT: return "FTP accept timeout";
        case CurlCode.CURLE_FTP_WEIRD_PASV_REPLY: return "FTP weird PASV reply";
        case CurlCode.CURLE_FTP_WEIRD_227_FORMAT: return "FTP weird 227 format";
        case CurlCode.CURLE_FTP_CANT_GET_HOST: return "FTP cannot get host";
        case CurlCode.CURLE_HTTP2: return "HTTP/2 error";
        case CurlCode.CURLE_FTP_COULDNT_SET_TYPE: return "FTP couldn't set transfer type";
        case CurlCode.CURLE_PARTIAL_FILE: return "Transferred a partial file";
        case CurlCode.CURLE_FTP_COULDNT_RETR_FILE: return "FTP couldn't retrieve file";
        case CurlCode.CURLE_QUOTE_ERROR: return "Quote error from FTP/file command";
        case CurlCode.CURLE_HTTP_RETURNED_ERROR: return "HTTP returned error";
        case CurlCode.CURLE_WRITE_ERROR: return "Failure writing received data";
        case CurlCode.CURLE_UPLOAD_FAILED: return "Upload failed";
        case CurlCode.CURLE_READ_ERROR: return "Failed to open/read local data";
        case CurlCode.CURLE_OUT_OF_MEMORY: return "Out of memory";
        case CurlCode.CURLE_OPERATION_TIMEDOUT: return "Operation timed out";
        case CurlCode.CURLE_FTP_PORT_FAILED: return "FTP PORT command failed";
        case CurlCode.CURLE_FTP_COULDNT_USE_REST: return "FTP REST command failed";
        case CurlCode.CURLE_RANGE_ERROR: return "Requested range not satisfiable";
        case CurlCode.CURLE_HTTP_POST_ERROR: return "HTTP post error";
        case CurlCode.CURLE_SSL_CONNECT_ERROR: return "SSL connect error";
        case CurlCode.CURLE_BAD_DOWNLOAD_RESUME: return "Bad download resume";
        case CurlCode.CURLE_FILE_COULDNT_READ_FILE: return "Couldn't read file";
        case CurlCode.CURLE_LDAP_CANNOT_BIND: return "LDAP cannot bind";
        case CurlCode.CURLE_LDAP_SEARCH_FAILED: return "LDAP search failed";
        case CurlCode.CURLE_FUNCTION_NOT_FOUND: return "Function not found";
        case CurlCode.CURLE_ABORTED_BY_CALLBACK: return "Operation was aborted by an application callback";
        case CurlCode.CURLE_BAD_FUNCTION_ARGUMENT: return "Function called with bad argument";
        case CurlCode.CURLE_INTERFACE_FAILED: return "Failed binding local connection interface";
        case CurlCode.CURLE_TOO_MANY_REDIRECTS: return "Too many redirects";
        case CurlCode.CURLE_UNKNOWN_OPTION: return "Unknown option passed to libcurl";
        case CurlCode.CURLE_SETOPT_OPTION_SYNTAX: return "Setopt option syntax error";
        case CurlCode.CURLE_GOT_NOTHING: return "Server returned nothing (no headers, no data)";
        case CurlCode.CURLE_SSL_ENGINE_NOTFOUND: return "SSL crypto engine not found";
        case CurlCode.CURLE_SSL_ENGINE_SETFAILED: return "Cannot set SSL crypto engine as default";
        case CurlCode.CURLE_SEND_ERROR: return "Failed sending data to the peer";
        case CurlCode.CURLE_RECV_ERROR: return "Failure when receiving data from the peer";
        case CurlCode.CURLE_SSL_CERTPROBLEM: return "Problem with the local SSL certificate";
        case CurlCode.CURLE_SSL_CIPHER: return "Couldn't use specified SSL cipher";
        case CurlCode.CURLE_PEER_FAILED_VERIFICATION: return "Peer certificate cannot be authenticated with known CA certificates";
        case CurlCode.CURLE_BAD_CONTENT_ENCODING: return "Unrecognized transfer encoding";
        case CurlCode.CURLE_FILESIZE_EXCEEDED: return "Maximum file size exceeded";
        case CurlCode.CURLE_USE_SSL_FAILED: return "Use of SSL failed";
        case CurlCode.CURLE_SEND_FAIL_REWIND: return "Send failed to rewind";
        case CurlCode.CURLE_SSL_ENGINE_INITFAILED: return "SSL engine initialization failed";
        case CurlCode.CURLE_LOGIN_DENIED: return "The remote server denied login";
        case CurlCode.CURLE_TFTP_NOTFOUND: return "TFTP file not found";
        case CurlCode.CURLE_TFTP_PERM: return "TFTP permission denied";
        case CurlCode.CURLE_REMOTE_DISK_FULL: return "Remote disk full";
        case CurlCode.CURLE_TFTP_ILLEGAL: return "TFTP illegal operation";
        case CurlCode.CURLE_TFTP_UNKNOWNID: return "TFTP unknown transfer ID";
        case CurlCode.CURLE_REMOTE_FILE_EXISTS: return "Remote file already exists";
        case CurlCode.CURLE_TFTP_NOSUCHUSER: return "TFTP no such user";
        case CurlCode.CURLE_SSL_CACERT: return "Peer certificate cannot be authenticated with known CA certificates (SSL CACERT)";
        case CurlCode.CURLE_REMOTE_FILE_NOT_FOUND: return "Remote file not found";
        case CurlCode.CURLE_SSH: return "SSH error";
        case CurlCode.CURLE_SSL_SHUTDOWN_FAILED: return "Failed to shut down the SSL connection";
        case CurlCode.CURLE_AGAIN: return "Socket not ready for send/recv, try again";
        case CurlCode.CURLE_SSL_CRL_BADFILE: return "Could not load CRL file";
        case CurlCode.CURLE_SSL_ISSUER_ERROR: return "Issuer check failed";
        case CurlCode.CURLE_FTP_PRET_FAILED: return "FTP server did not accept PRET command";
        case CurlCode.CURLE_RTSP_CSEQ_ERROR: return "RTSP CSeq mismatch or invalid CSeq";
        case CurlCode.CURLE_RTSP_SESSION_ERROR: return "RTSP session error";
        case CurlCode.CURLE_FTP_BAD_FILE_LIST: return "Unable to parse FTP file list";
        case CurlCode.CURLE_CHUNK_FAILED: return "Chunk callback failed";
        case CurlCode.CURLE_NO_CONNECTION_AVAILABLE: return "No connection available in pool";
        case CurlCode.CURLE_SSL_PINNEDPUBKEYNOTMATCH: return "SSL public key does not match pinned public key";
        case CurlCode.CURLE_SSL_INVALIDCERTSTATUS: return "SSL certificate status verification failed";
        case CurlCode.CURLE_HTTP2_STREAM: return "Stream error in the HTTP/2 framing layer";
        case CurlCode.CURLE_RECURSIVE_API_CALL: return "API function called from within callback";
        case CurlCode.CURLE_AUTH_ERROR: return "Authentication error";
        case CurlCode.CURLE_HTTP3: return "HTTP/3 error";
        case CurlCode.CURLE_QUIC_CONNECT_ERROR: return "QUIC connection error";
        case CurlCode.CURLE_PROXY: return "Proxy handshake error";
        case CurlCode.CURLE_SSL_CLIENTCERT: return "SSL client-side certificate required";
        case CurlCode.CURLE_UNRECOVERABLE_POLL: return "Unrecoverable error in select/poll";
        case CurlCode.CURLE_TOO_LARGE: return "Data field grew larger than allowed";
        case CurlCode.CURLE_ECH_REQUIRED: return "ECH attempted but failed";
        default: return "Unknown libcurl error";
    }
}

/// Queries libcurl's native `curl_easy_strerror` string without GC allocation.
const(char)[] curlStrerror(CurlCode code) @trusted @nogc nothrow
{
    const(char)* p = curl_easy_strerror(cast(CURLcode) code);
    if (p is null)
        return null;
    import core.stdc.string : strlen;
    return p[0 .. strlen(p)];
}

/// Exception representing an error returned by libcurl.
///
/// Preserves the original `CurlCode` for programmatic error handling and inspection.
class CurlException : Exception
{
    CurlCode code;

    /// Primary `@nogc` constructor using a pre-allocated or literal message.
    @nogc @safe nothrow this(CurlCode code, string msg, string file = __FILE__, size_t line = __LINE__)
    in (code != CurlCode.CURLE_OK, "CurlException cannot be constructed with CURLE_OK")
    {
        super(msg, file, line);
        this.code = code;
    }

    /// Convenience constructor using GC allocation to generate a descriptive error message.
    @safe this(CurlCode code)
    in (code != CurlCode.CURLE_OK, "CurlException cannot be constructed with CURLE_OK")
    {
        import std.format : format;
        this(code, format("%s (%d): %s", curlCodeToString(code), cast(int) code, curlCodeDescription(code)));
    }
}

/// Exception representing an aborted or cancelled transfer (EV-4).
///
/// Subclass of `CurlException` preserving `CurlCode.CURLE_ABORTED_BY_CALLBACK`.
class CancelledException : CurlException
{
    @nogc @safe nothrow this(string msg = "Transfer was cancelled", string file = __FILE__, size_t line = __LINE__)
    {
        super(CurlCode.CURLE_ABORTED_BY_CALLBACK, msg, file, line);
    }
}

/// Exception representing a request or connect timeout (TC-11).
///
/// Subclass of `CurlException` preserving `CurlCode.CURLE_OPERATION_TIMEDOUT`.
class TimeoutException : CurlException
{
    @nogc @safe nothrow this(string msg = "Operation timed out", string file = __FILE__, size_t line = __LINE__)
    {
        super(CurlCode.CURLE_OPERATION_TIMEDOUT, msg, file, line);
    }
}

/// Exception representing an excessive redirect chain (TC-11).
///
/// Subclass of `CurlException` preserving `CurlCode.CURLE_TOO_MANY_REDIRECTS`.
class TooManyRedirectsException : CurlException
{
    @nogc @safe nothrow this(string msg = "Too many redirects", string file = __FILE__, size_t line = __LINE__)
    {
        super(CurlCode.CURLE_TOO_MANY_REDIRECTS, msg, file, line);
    }
}

/// Strongly-typed curl multi return codes, directly corresponding to libcurl's `CURLMcode`.
enum CurlMCode : int
{
    CURLM_CALL_MULTI_PERFORM    = -1,
    CURLM_OK                    = 0,
    CURLM_BAD_HANDLE            = 1,
    CURLM_BAD_EASY_HANDLE       = 2,
    CURLM_OUT_OF_MEMORY         = 3,
    CURLM_INTERNAL_ERROR        = 4,
    CURLM_BAD_SOCKET            = 5,
    CURLM_UNKNOWN_OPTION        = 6,
    CURLM_ADDED_ALREADY         = 7,
    CURLM_RECURSIVE_API_CALL    = 8,
    CURLM_WAKEUP_FAILURE        = 9,
    CURLM_BAD_FUNCTION_ARGUMENT = 10,
    CURLM_ABORTED_BY_CALLBACK   = 11,
    CURLM_UNRECOVERABLE_POLL    = 12,
    CURLM_LAST                  = 13,
}

pure @safe @nogc nothrow string curlMCodeToString(CurlMCode code)
{
    switch (code)
    {
        case CurlMCode.CURLM_CALL_MULTI_PERFORM: return "CURLM_CALL_MULTI_PERFORM";
        case CurlMCode.CURLM_OK: return "CURLM_OK";
        case CurlMCode.CURLM_BAD_HANDLE: return "CURLM_BAD_HANDLE";
        case CurlMCode.CURLM_BAD_EASY_HANDLE: return "CURLM_BAD_EASY_HANDLE";
        case CurlMCode.CURLM_OUT_OF_MEMORY: return "CURLM_OUT_OF_MEMORY";
        case CurlMCode.CURLM_INTERNAL_ERROR: return "CURLM_INTERNAL_ERROR";
        case CurlMCode.CURLM_BAD_SOCKET: return "CURLM_BAD_SOCKET";
        case CurlMCode.CURLM_UNKNOWN_OPTION: return "CURLM_UNKNOWN_OPTION";
        case CurlMCode.CURLM_ADDED_ALREADY: return "CURLM_ADDED_ALREADY";
        case CurlMCode.CURLM_RECURSIVE_API_CALL: return "CURLM_RECURSIVE_API_CALL";
        case CurlMCode.CURLM_WAKEUP_FAILURE: return "CURLM_WAKEUP_FAILURE";
        case CurlMCode.CURLM_BAD_FUNCTION_ARGUMENT: return "CURLM_BAD_FUNCTION_ARGUMENT";
        case CurlMCode.CURLM_ABORTED_BY_CALLBACK: return "CURLM_ABORTED_BY_CALLBACK";
        case CurlMCode.CURLM_UNRECOVERABLE_POLL: return "CURLM_UNRECOVERABLE_POLL";
        default: return "CURLM_UNKNOWN";
    }
}

pure @safe @nogc nothrow string curlMCodeDescription(CurlMCode code)
{
    switch (code)
    {
        case CurlMCode.CURLM_CALL_MULTI_PERFORM: return "Please call curl_multi_perform immediately";
        case CurlMCode.CURLM_OK: return "No error";
        case CurlMCode.CURLM_BAD_HANDLE: return "Invalid multi handle";
        case CurlMCode.CURLM_BAD_EASY_HANDLE: return "Invalid easy handle passed to multi interface";
        case CurlMCode.CURLM_OUT_OF_MEMORY: return "Out of memory in multi interface";
        case CurlMCode.CURLM_INTERNAL_ERROR: return "Internal libcurl multi error";
        case CurlMCode.CURLM_BAD_SOCKET: return "Invalid socket argument";
        case CurlMCode.CURLM_UNKNOWN_OPTION: return "Unknown multi option";
        case CurlMCode.CURLM_ADDED_ALREADY: return "Easy handle already added to a multi handle";
        case CurlMCode.CURLM_RECURSIVE_API_CALL: return "API function called from within callback";
        case CurlMCode.CURLM_WAKEUP_FAILURE: return "Wakeup failure";
        case CurlMCode.CURLM_BAD_FUNCTION_ARGUMENT: return "Bad function argument in multi interface";
        case CurlMCode.CURLM_ABORTED_BY_CALLBACK: return "Operation aborted by callback in multi interface";
        case CurlMCode.CURLM_UNRECOVERABLE_POLL: return "Unrecoverable poll error in multi interface";
        default: return "Unknown libcurl multi error";
    }
}

/// Queries libcurl's native `curl_multi_strerror` string without GC allocation.
const(char)[] curlMultiStrerror(CurlMCode code) @trusted @nogc nothrow
{
    const(char)* p = curl_multi_strerror(cast(CURLMcode) code);
    if (p is null)
        return null;
    import core.stdc.string : strlen;
    return p[0 .. strlen(p)];
}

/// Exception representing an error returned by libcurl's multi interface.
class CurlMultiException : Exception
{
    CurlMCode code;

    @nogc @safe nothrow this(CurlMCode code, string msg, string file = __FILE__, size_t line = __LINE__)
    in (code != CurlMCode.CURLM_OK, "CurlMultiException cannot be constructed with CURLM_OK")
    {
        super(msg, file, line);
        this.code = code;
    }

    @safe this(CurlMCode code)
    in (code != CurlMCode.CURLM_OK, "CurlMultiException cannot be constructed with CURLM_OK")
    {
        import std.format : format;
        this(code, format("%s (%d): %s", curlMCodeToString(code), cast(int) code, curlMCodeDescription(code)));
    }
}

// --- Preallocated exceptions for @nogc execution paths ---

// Shared preallocated exceptions for @nogc throw sites.
// Initialized in shared static this() so foreign threads (e.g. C callbacks,
// pthread_create, Slint UI workers) that do not run D runtime TLS static this()
// can safely throw without dereferencing null or triggering SIGSEGV.
private __gshared CurlException[128] _preallocatedErrors;
private __gshared CurlException _globalFallbackError;
private __gshared CancelledException _preallocatedCancelled;
private __gshared TimeoutException _preallocatedTimeout;
private __gshared TooManyRedirectsException _preallocatedTooManyRedirects;
private __gshared CurlMultiException[16] _preallocatedMultiErrors;
private __gshared CurlMultiException _globalMultiFallbackError;

shared static this()
{
    _globalFallbackError = new CurlException(cast(CurlCode) -1, "Unknown libcurl error");
    _preallocatedCancelled = new CancelledException("Transfer was cancelled");
    _preallocatedTimeout = new TimeoutException("Operation timed out");
    _preallocatedTooManyRedirects = new TooManyRedirectsException("Too many redirects");
    _globalMultiFallbackError = new CurlMultiException(cast(CurlMCode) -99, "Unknown libcurl multi error");

    foreach (int i; 1 .. 128)
    {
        auto c = cast(CurlCode) i;
        _preallocatedErrors[i] = new CurlException(c, curlCodeDescription(c));
    }
    _preallocatedErrors[cast(int) CurlCode.CURLE_OPERATION_TIMEDOUT] = _preallocatedTimeout;
    _preallocatedErrors[cast(int) CurlCode.CURLE_TOO_MANY_REDIRECTS] = _preallocatedTooManyRedirects;

    foreach (int i; 1 .. 16)
    {
        auto mc = cast(CurlMCode) i;
        _preallocatedMultiErrors[i] = new CurlMultiException(mc, curlMCodeDescription(mc));
    }
}

/// Throws a preallocated `CancelledException` without GC allocation (EV-4).
@nogc @trusted void throwCancelledNogc(string msg = "Transfer was cancelled", string file = __FILE__, size_t line = __LINE__)
{
    if (_preallocatedCancelled !is null)
        throw _preallocatedCancelled;
    if (_globalFallbackError !is null)
        throw _globalFallbackError;
    assert(0, "throwCancelledNogc called before shared static initialization");
}

/// Throws a preallocated `CurlMultiException` matching `code` without any GC allocation.
@nogc @trusted void throwCurlMultiErrorNogc(CurlMCode code, string file = __FILE__, size_t line = __LINE__)
{
    if (code == CurlMCode.CURLM_OK)
        return;

    int idx = cast(int) code;
    if (idx > 0 && idx < _preallocatedMultiErrors.length && _preallocatedMultiErrors[idx] !is null)
    {
        throw _preallocatedMultiErrors[idx];
    }
    if (_globalMultiFallbackError !is null)
    {
        throw _globalMultiFallbackError;
    }
    assert(0, "throwCurlMultiErrorNogc called before shared static initialization");
}

/// Enforces that a `CurlMCode` is `CURLM_OK` under `@nogc`, throwing a preallocated `CurlMultiException` on failure.
@nogc @safe void enforceCurlMultiNogc(CurlMCode code, string file = __FILE__, size_t line = __LINE__)
{
    if (code != CurlMCode.CURLM_OK)
        throwCurlMultiErrorNogc(code, file, line);
}

/// Enforces that a `CurlMCode` is `CURLM_OK`, throwing a `CurlMultiException` on failure.
@safe void enforceCurlMulti(CurlMCode code, string customMsg = null, string file = __FILE__, size_t line = __LINE__)
{
    if (code == CurlMCode.CURLM_OK)
        return;

    if (customMsg.length > 0)
    {
        throw new CurlMultiException(code, customMsg, file, line);
    }
    throw new CurlMultiException(code);
}

/// Throws a preallocated `CurlException` matching `code` without any GC allocation.
@nogc @trusted void throwCurlErrorNogc(CurlCode code, string file = __FILE__, size_t line = __LINE__)
{
    if (code == CurlCode.CURLE_OK)
        return;

    if (code == CurlCode.CURLE_ABORTED_BY_CALLBACK && _preallocatedCancelled !is null)
    {
        throw _preallocatedCancelled;
    }
    if (code == CurlCode.CURLE_OPERATION_TIMEDOUT && _preallocatedTimeout !is null)
    {
        throw _preallocatedTimeout;
    }
    if (code == CurlCode.CURLE_TOO_MANY_REDIRECTS && _preallocatedTooManyRedirects !is null)
    {
        throw _preallocatedTooManyRedirects;
    }

    int idx = cast(int) code;
    if (idx > 0 && idx < _preallocatedErrors.length && _preallocatedErrors[idx] !is null)
    {
        throw _preallocatedErrors[idx];
    }
    if (_globalFallbackError !is null)
    {
        throw _globalFallbackError;
    }
    assert(0, "throwCurlErrorNogc called before shared static initialization");
}

/// Enforces that a `CurlCode` is `CURLE_OK` under `@nogc`, throwing a preallocated `CurlException` on failure.
@nogc @safe void enforceCurlNogc(CurlCode code, string file = __FILE__, size_t line = __LINE__)
{
    if (code != CurlCode.CURLE_OK)
        throwCurlErrorNogc(code, file, line);
}

/// Enforces that a `CurlCode` is `CURLE_OK`, throwing a `CurlException` on failure.
@safe void enforceCurl(CurlCode code, string customMsg = null, string file = __FILE__, size_t line = __LINE__)
{
    if (code == CurlCode.CURLE_OK)
        return;

    if (code == CurlCode.CURLE_ABORTED_BY_CALLBACK)
    {
        if (customMsg.length > 0)
            throw new CancelledException(customMsg, file, line);
        throw new CancelledException("Transfer was cancelled", file, line);
    }

    if (code == CurlCode.CURLE_OPERATION_TIMEDOUT)
    {
        if (customMsg.length > 0)
            throw new TimeoutException(customMsg, file, line);
        throw new TimeoutException("Operation timed out", file, line);
    }

    if (code == CurlCode.CURLE_TOO_MANY_REDIRECTS)
    {
        if (customMsg.length > 0)
            throw new TooManyRedirectsException(customMsg, file, line);
        throw new TooManyRedirectsException("Too many redirects", file, line);
    }

    if (customMsg.length > 0)
    {
        throw new CurlException(code, customMsg, file, line);
    }
    throw new CurlException(code);
}

/// Returns the standard HTTP status reason phrase for common status codes in pure `@safe @nogc nothrow`.
pure @safe @nogc nothrow string defaultHttpStatusText(int statusCode)
{
    switch (statusCode)
    {
        case 100: return "Continue";
        case 101: return "Switching Protocols";
        case 103: return "Early Hints";
        case 200: return "OK";
        case 201: return "Created";
        case 202: return "Accepted";
        case 204: return "No Content";
        case 206: return "Partial Content";
        case 301: return "Moved Permanently";
        case 302: return "Found";
        case 303: return "See Other";
        case 304: return "Not Modified";
        case 307: return "Temporary Redirect";
        case 308: return "Permanent Redirect";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 406: return "Not Acceptable";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 410: return "Gone";
        case 413: return "Content Too Large";
        case 415: return "Unsupported Media Type";
        case 422: return "Unprocessable Entity";
        case 426: return "Upgrade Required";
        case 429: return "Too Many Requests";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 502: return "Bad Gateway";
        case 503: return "Service Unavailable";
        case 504: return "Gateway Timeout";
        case 505: return "HTTP Version Not Supported";
        default: return "HTTP Error";
    }
}

/// Exception representing an unexpected or error HTTP response status code (e.g. 4xx, 5xx).
class HttpStatusException : Exception
{
    int statusCode;
    string statusText;

    invariant
    {
        assert(statusCode >= 100 && statusCode <= 599, "statusCode must be in 100..599");
    }

    /// Primary `@nogc` constructor.
    @nogc @safe nothrow this(int statusCode, string msg, string file = __FILE__, size_t line = __LINE__)
        in (statusCode >= 100 && statusCode <= 599, "statusCode must be between 100 and 599")
    {
        super(msg, file, line);
        this.statusCode = statusCode;
        this.statusText = defaultHttpStatusText(statusCode);
    }

    /// Convenience constructor with auto-formatted status message.
    @safe this(int statusCode)
    {
        import std.format : format;
        this(statusCode, format("HTTP %d: %s", statusCode, defaultHttpStatusText(statusCode)));
    }

    /// Static factory allowing a custom status text reason phrase.
    static HttpStatusException fromStatus(int statusCode, string customReason = null, string file = __FILE__, size_t line = __LINE__) @safe
    {
        import std.format : format;
        string text = customReason.length ? customReason : defaultHttpStatusText(statusCode);
        auto ex = new HttpStatusException(statusCode, format("HTTP %d: %s", statusCode, text), file, line);
        ex.statusText = text;
        return ex;
    }
}

/// Checks whether an HTTP status code is in the 1xx Informational class.
pure @safe @nogc nothrow bool isInformational(int statusCode)
{
    return statusCode >= 100 && statusCode <= 199;
}

/// Checks whether an HTTP status code is in the 2xx Success class.
pure @safe @nogc nothrow bool isSuccess(int statusCode)
{
    return statusCode >= 200 && statusCode <= 299;
}

/// Checks whether an HTTP status code is in the 3xx Redirection class.
pure @safe @nogc nothrow bool isRedirection(int statusCode)
{
    return statusCode >= 300 && statusCode <= 399;
}

/// Checks whether an HTTP status code is in the 4xx Client Error class.
pure @safe @nogc nothrow bool isClientError(int statusCode)
{
    return statusCode >= 400 && statusCode <= 499;
}

/// Checks whether an HTTP status code is in the 5xx Server Error class.
pure @safe @nogc nothrow bool isServerError(int statusCode)
{
    return statusCode >= 500 && statusCode <= 599;
}

/// Enforces that an HTTP status code is in the 2xx Success range, throwing `HttpStatusException` otherwise.
@safe void enforceSuccessStatus(int statusCode, string customMsg = null, string file = __FILE__, size_t line = __LINE__)
{
    if (isSuccess(statusCode))
        return;

    throw HttpStatusException.fromStatus(statusCode, customMsg, file, line);
}

// --- Unittests for slate.http.error ---

// Spec: libcurl CURLcode table and curl_easy_strerror(3) mapping
/// Example:
/// ---
/// import slate.http.error;
/// string name = curlCodeToString(CurlCode.CURLE_COULDNT_CONNECT);
/// assert(name == "CURLE_COULDNT_CONNECT");
/// string desc = curlCodeDescription(CurlCode.CURLE_COULDNT_CONNECT);
/// assert(desc.length > 0);
/// ---
unittest
{
    // Table test: verify bidirectional mapping and string descriptions
    struct ErrorCase
    {
        CurlCode code;
        string expectedSymbol;
        string expectedNative;
    }

    static immutable ErrorCase[] cases = [
        ErrorCase(CurlCode.CURLE_OK, "CURLE_OK", "No error"),
        ErrorCase(CurlCode.CURLE_COULDNT_RESOLVE_HOST, "CURLE_COULDNT_RESOLVE_HOST", "Could not resolve hostname"),
        ErrorCase(CurlCode.CURLE_COULDNT_CONNECT, "CURLE_COULDNT_CONNECT", "Could not connect to server"),
        ErrorCase(CurlCode.CURLE_OPERATION_TIMEDOUT, "CURLE_OPERATION_TIMEDOUT", "Timeout was reached"),
        ErrorCase(CurlCode.CURLE_SSL_CONNECT_ERROR, "CURLE_SSL_CONNECT_ERROR", "SSL connect error"),
        ErrorCase(CurlCode.CURLE_PEER_FAILED_VERIFICATION, "CURLE_PEER_FAILED_VERIFICATION", "SSL peer certificate or SSH remote key was not OK"),
        ErrorCase(CurlCode.CURLE_TOO_MANY_REDIRECTS, "CURLE_TOO_MANY_REDIRECTS", "Number of redirects hit maximum amount"),
        ErrorCase(CurlCode.CURLE_HTTP2, "CURLE_HTTP2", "Error in the HTTP2 framing layer"),
        ErrorCase(CurlCode.CURLE_HTTP3, "CURLE_HTTP3", "HTTP/3 error"),
        ErrorCase(CurlCode.CURLE_QUIC_CONNECT_ERROR, "CURLE_QUIC_CONNECT_ERROR", "QUIC connection error"),
    ];

    foreach (c; cases)
    {
        assert(curlCodeToString(c.code) == c.expectedSymbol,
            "curlCodeToString mismatch for code " ~ c.expectedSymbol);
        assert(curlCodeDescription(c.code).length > 0,
            "curlCodeDescription should be non-empty for code " ~ c.expectedSymbol);
        // Verify native strerror lookup against linked libcurl
        const(char)[] nativeMsg = curlStrerror(c.code);
        assert(nativeMsg == c.expectedNative,
            "curlStrerror mismatch for " ~ c.expectedSymbol ~ ": got '" ~ nativeMsg.idup ~ "', expected '" ~ c.expectedNative ~ "'");
    }
}

// Spec: Exception propagation and code preservation for CurlException
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     enforceCurl(CurlCode.CURLE_COULDNT_CONNECT);
/// } catch (CurlException e) {
///     assert(e.code == CurlCode.CURLE_COULDNT_CONNECT);
/// }
/// ---
unittest
{
    // Verify throw and catch preserves the error code
    bool caught = false;
    try
    {
        enforceCurl(CurlCode.CURLE_COULDNT_CONNECT);
    }
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_COULDNT_CONNECT, "CurlException must preserve error code");
        assert(e.msg.length > 0, "CurlException msg should be non-empty");
    }
    assert(caught, "enforceCurl must throw on error");

    // Success code should not throw
    enforceCurl(CurlCode.CURLE_OK);
}

// Best practice: verify preallocated @nogc exception throwing without GC allocation
/// Example:
/// ---
/// import slate.http.error;
/// @nogc void riskyCall() {
///     enforceCurlNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
/// }
/// ---
unittest
{
    @nogc void performNogcCheck(CurlCode code)
    {
        enforceCurlNogc(code);
    }

    // Success path under @nogc does not throw
    performNogcCheck(CurlCode.CURLE_OK);

    // Failure path under @nogc throws preallocated exception
    bool caught = false;
    try
    {
        performNogcCheck(CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    catch (CurlException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
        assert(e.msg == curlCodeDescription(CurlCode.CURLE_OPERATION_TIMEDOUT));
    }
    assert(caught, "enforceCurlNogc must throw on non-OK code");
}

// Best practice: Thread safety of @nogc preallocated exceptions in worker threads
/// Example:
/// ---
/// import slate.http.error;
/// import core.thread : Thread;
/// auto t = new Thread({
///     enforceCurlNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
/// });
/// t.start();
/// t.join();
/// ---
unittest
{
    import core.thread : Thread;

    bool threadCaught = false;
    CurlCode caughtCode;

    auto t = new Thread({
        try
        {
            enforceCurlNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
        }
        catch (CurlException e)
        {
            threadCaught = true;
            caughtCode = e.code;
        }
    });
    t.start();
    t.join();

    assert(threadCaught, "Worker thread must successfully throw and catch preallocated CurlException");
    assert(caughtCode == CurlCode.CURLE_OPERATION_TIMEDOUT);
}

// Spec: RFC 9110 HTTP Semantics status code classification and HttpStatusException contracts
/// Example:
/// ---
/// import slate.http.error;
/// assert(isSuccess(200));
/// assert(isClientError(404));
/// try {
///     enforceSuccessStatus(500);
/// } catch (HttpStatusException e) {
///     assert(e.statusCode == 500);
/// }
/// ---
unittest
{
    // Status classification tests
    assert(isInformational(101));
    assert(!isInformational(200));

    assert(isSuccess(200));
    assert(isSuccess(204));
    assert(!isSuccess(404));

    assert(isRedirection(301));
    assert(isRedirection(302));

    assert(isClientError(400));
    assert(isClientError(404));
    assert(isClientError(429));

    assert(isServerError(500));
    assert(isServerError(502));
    assert(isServerError(503));

    // HttpStatusException throw/catch test
    bool caught = false;
    try
    {
        enforceSuccessStatus(404);
    }
    catch (HttpStatusException e)
    {
        caught = true;
        assert(e.statusCode == 404);
        assert(e.statusText == "Not Found");
    }
    assert(caught, "enforceSuccessStatus must throw for 404");

    // Success does not throw
    enforceSuccessStatus(200);

    // Verify @nogc constructor and reason phrase mapping
    auto ex = new HttpStatusException(503, "Service Unavailable");
    assert(ex.statusCode == 503);
    assert(ex.statusText == "Service Unavailable");

    // Negative contract tests: invalid status codes and CURLE_OK must trigger AssertError
    import std.exception : assertThrown;
    import core.exception : AssertError;

    assertThrown!AssertError(new CurlException(CurlCode.CURLE_OK));
    assertThrown!AssertError(new HttpStatusException(99));
    assertThrown!AssertError(new HttpStatusException(600));
}

// Spec: libcurl progress callback cancellation and error mapping (EV-4)
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     throwCancelledNogc();
/// } catch (CancelledException e) {
///     assert(e.code == CurlCode.CURLE_ABORTED_BY_CALLBACK);
/// }
/// ---
unittest
{
    // Best practice: verify CancelledException preserves CURLE_ABORTED_BY_CALLBACK under @nogc
    @nogc void checkCancel()
    {
        throwCancelledNogc();
    }

    bool caught = false;
    try
    {
        checkCancel();
    }
    catch (CancelledException e)
    {
        caught = true;
        assert(e.code == CurlCode.CURLE_ABORTED_BY_CALLBACK);
        assert(e.msg == "Transfer was cancelled");
    }
    assert(caught, "CancelledException must be caught as CancelledException");
}

// Spec: curl_multi_strerror(3) and CurlMultiException code preservation
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     enforceCurlMulti(CurlMCode.CURLM_BAD_HANDLE);
/// } catch (CurlMultiException e) {
///     assert(e.code == CurlMCode.CURLM_BAD_HANDLE);
/// }
/// ---
unittest
{
    // Best practice: verify CurlMultiException preserves code and @nogc preallocated throw
    assert(curlMCodeToString(CurlMCode.CURLM_OK) == "CURLM_OK");
    assert(curlMCodeToString(CurlMCode.CURLM_BAD_HANDLE) == "CURLM_BAD_HANDLE");
    assert(curlMultiStrerror(CurlMCode.CURLM_OK) !is null);

    bool caught = false;
    try
    {
        enforceCurlMulti(CurlMCode.CURLM_BAD_HANDLE);
    }
    catch (CurlMultiException e)
    {
        caught = true;
        assert(e.code == CurlMCode.CURLM_BAD_HANDLE);
    }
    assert(caught, "enforceCurlMulti must throw on error code");

    @nogc void checkMultiNogc()
    {
        enforceCurlMultiNogc(CurlMCode.CURLM_OUT_OF_MEMORY);
    }

    bool caughtNogc = false;
    try
    {
        checkMultiNogc();
    }
    catch (CurlMultiException e)
    {
        caughtNogc = true;
        assert(e.code == CurlMCode.CURLM_OUT_OF_MEMORY);
    }
    assert(caughtNogc, "enforceCurlMultiNogc must throw under @nogc");

    // Success code must not throw
    enforceCurlMulti(CurlMCode.CURLM_OK);
    enforceCurlMultiNogc(CurlMCode.CURLM_OK);
}

// Spec: CURLE_OPERATION_TIMEDOUT and CURLE_TOO_MANY_REDIRECTS typed exception mapping (TC-11)
/// Example:
/// ---
/// import slate.http.error;
/// try {
///     enforceCurl(CurlCode.CURLE_OPERATION_TIMEDOUT);
/// } catch (TimeoutException e) {
///     assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
/// }
/// ---
unittest
{
    // Best practice: verify TimeoutException and TooManyRedirectsException in both GC and @nogc paths
    bool caughtTimeout = false;
    try
    {
        enforceCurl(CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    catch (TimeoutException e)
    {
        caughtTimeout = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    assert(caughtTimeout);

    bool caughtTimeoutNogc = false;
    @nogc void checkTimeoutNogc()
    {
        throwCurlErrorNogc(CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    try
    {
        checkTimeoutNogc();
    }
    catch (TimeoutException e)
    {
        caughtTimeoutNogc = true;
        assert(e.code == CurlCode.CURLE_OPERATION_TIMEDOUT);
    }
    assert(caughtTimeoutNogc);

    bool caughtRedir = false;
    try
    {
        enforceCurl(CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    catch (TooManyRedirectsException e)
    {
        caughtRedir = true;
        assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    assert(caughtRedir);

    bool caughtRedirNogc = false;
    @nogc void checkRedirNogc()
    {
        throwCurlErrorNogc(CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    try
    {
        checkRedirNogc();
    }
    catch (TooManyRedirectsException e)
    {
        caughtRedirNogc = true;
        assert(e.code == CurlCode.CURLE_TOO_MANY_REDIRECTS);
    }
    assert(caughtRedirNogc);
}
