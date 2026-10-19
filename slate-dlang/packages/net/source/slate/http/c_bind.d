/// Private / package-internal C bindings to libcurl.
///
/// This module provides `@system extern(C)` declarations for libcurl symbols,
/// option enums, and data structs. Public APIs must wrap these in `@safe` or
/// `@trusted` abstractions and never expose raw `CURLOPT_*` constants or raw
/// pointers.
///
/// Notice: Under no circumstance may `etc.c.curl` be imported in this module
/// or anywhere in `slate.http` (UB-2).
module slate.http.c_bind;

import core.stdc.config : c_long, c_ulong;
import core.stdc.stdio : FILE;

package:

alias curl_off_t = long;
alias curl_socket_t = int;

// Type-safe opaque handle types
struct CURL;
struct CURLM;
struct CURLSH;

// --- Global initialization flags ---
enum CURL_GLOBAL_SSL = 1L << 0;
enum CURL_GLOBAL_WIN32 = 1L << 1;
enum CURL_GLOBAL_ALL = CURL_GLOBAL_SSL | CURL_GLOBAL_WIN32;
enum CURL_GLOBAL_NOTHING = 0L;
enum CURL_GLOBAL_DEFAULT = CURL_GLOBAL_ALL;
enum CURL_GLOBAL_ACK_EINTR = 1L << 2;

// --- CURLcode ---
enum CURLcode : int
{
    CURLE_OK = 0,
    CURLE_UNSUPPORTED_PROTOCOL, /* 1 */
    CURLE_FAILED_INIT, /* 2 */
    CURLE_URL_MALFORMAT, /* 3 */
    CURLE_NOT_BUILT_IN, /* 4 */
    CURLE_COULDNT_RESOLVE_PROXY, /* 5 */
    CURLE_COULDNT_RESOLVE_HOST, /* 6 */
    CURLE_COULDNT_CONNECT, /* 7 */
    CURLE_WEIRD_SERVER_REPLY, /* 8 */
    CURLE_REMOTE_ACCESS_DENIED, /* 9 */
    CURLE_FTP_ACCEPT_FAILED, /* 10 */
    CURLE_FTP_WEIRD_PASS_REPLY, /* 11 */
    CURLE_FTP_ACCEPT_TIMEOUT, /* 12 */
    CURLE_FTP_WEIRD_PASV_REPLY, /* 13 */
    CURLE_FTP_WEIRD_227_FORMAT, /* 14 */
    CURLE_FTP_CANT_GET_HOST, /* 15 */
    CURLE_HTTP2, /* 16 */
    CURLE_FTP_COULDNT_SET_TYPE, /* 17 */
    CURLE_PARTIAL_FILE, /* 18 */
    CURLE_FTP_COULDNT_RETR_FILE, /* 19 */
    CURLE_QUOTE_ERROR = 21, /* 21 */
    CURLE_HTTP_RETURNED_ERROR, /* 22 */
    CURLE_WRITE_ERROR, /* 23 */
    CURLE_UPLOAD_FAILED = 25, /* 25 */
    CURLE_READ_ERROR, /* 26 */
    CURLE_OUT_OF_MEMORY, /* 27 */
    CURLE_OPERATION_TIMEDOUT, /* 28 */
    CURLE_FTP_PORT_FAILED = 30, /* 30 */
    CURLE_FTP_COULDNT_USE_REST, /* 31 */
    CURLE_RANGE_ERROR = 33, /* 33 */
    CURLE_HTTP_POST_ERROR, /* 34 */
    CURLE_SSL_CONNECT_ERROR, /* 35 */
    CURLE_BAD_DOWNLOAD_RESUME, /* 36 */
    CURLE_FILE_COULDNT_READ_FILE, /* 37 */
    CURLE_LDAP_CANNOT_BIND, /* 38 */
    CURLE_LDAP_SEARCH_FAILED, /* 39 */
    CURLE_FUNCTION_NOT_FOUND = 41, /* 41 */
    CURLE_ABORTED_BY_CALLBACK, /* 42 */
    CURLE_BAD_FUNCTION_ARGUMENT, /* 43 */
    CURLE_INTERFACE_FAILED = 45, /* 45 */
    CURLE_TOO_MANY_REDIRECTS = 47, /* 47 */
    CURLE_UNKNOWN_OPTION, /* 48 */
    CURLE_SETOPT_OPTION_SYNTAX, /* 49 */
    CURLE_GOT_NOTHING = 52, /* 52 */
    CURLE_SSL_ENGINE_NOTFOUND, /* 53 */
    CURLE_SSL_ENGINE_SETFAILED, /* 54 */
    CURLE_SEND_ERROR, /* 55 */
    CURLE_RECV_ERROR, /* 56 */
    CURLE_SSL_CERTPROBLEM = 58, /* 58 */
    CURLE_SSL_CIPHER, /* 59 */
    CURLE_PEER_FAILED_VERIFICATION, /* 60 */
    CURLE_BAD_CONTENT_ENCODING, /* 61 */
    CURLE_FILESIZE_EXCEEDED = 63, /* 63 */
    CURLE_USE_SSL_FAILED, /* 64 */
    CURLE_SEND_FAIL_REWIND, /* 65 */
    CURLE_SSL_ENGINE_INITFAILED, /* 66 */
    CURLE_LOGIN_DENIED, /* 67 */
    CURLE_TFTP_NOTFOUND, /* 68 */
    CURLE_TFTP_PERM, /* 69 */
    CURLE_REMOTE_DISK_FULL, /* 70 */
    CURLE_TFTP_ILLEGAL, /* 71 */
    CURLE_TFTP_UNKNOWNID, /* 72 */
    CURLE_REMOTE_FILE_EXISTS, /* 73 */
    CURLE_TFTP_NOSUCHUSER, /* 74 */
    CURLE_SSL_CACERT = 77, /* 77 */
    CURLE_REMOTE_FILE_NOT_FOUND = 78, /* 78 */
    CURLE_SSH = 79, /* 79 */
    CURLE_SSL_SHUTDOWN_FAILED, /* 80 */
    CURLE_AGAIN, /* 81 */
    CURLE_SSL_CRL_BADFILE = 82,
    CURLE_SSL_ISSUER_ERROR = 83,
    CURLE_FTP_PRET_FAILED = 84,
    CURLE_RTSP_CSEQ_ERROR = 85,
    CURLE_RTSP_SESSION_ERROR = 86,
    CURLE_FTP_BAD_FILE_LIST = 87,
    CURLE_CHUNK_FAILED = 88,
    CURLE_NO_CONNECTION_AVAILABLE = 89,
    CURLE_SSL_PINNEDPUBKEYNOTMATCH = 90,
    CURLE_SSL_INVALIDCERTSTATUS = 91,
    CURLE_HTTP2_STREAM = 92,
    CURLE_RECURSIVE_API_CALL = 93,
    CURLE_AUTH_ERROR = 94,
    CURLE_HTTP3 = 95,
    CURLE_QUIC_CONNECT_ERROR = 96,
    CURLE_PROXY = 97,
    CURLE_SSL_CLIENTCERT = 98,
    CURLE_UNRECOVERABLE_POLL = 99,
    CURLE_TOO_LARGE = 100,
    CURLE_ECH_REQUIRED = 101,
    CURL_LAST /* never use */
}

// --- CURLMcode ---
enum CURLMcode : int
{
    CURLM_CALL_MULTI_PERFORM = -1,
    CURLM_OK = 0,
    CURLM_BAD_HANDLE,
    CURLM_BAD_EASY_HANDLE,
    CURLM_OUT_OF_MEMORY,
    CURLM_INTERNAL_ERROR,
    CURLM_BAD_SOCKET,
    CURLM_UNKNOWN_OPTION,
    CURLM_ADDED_ALREADY,
    CURLM_RECURSIVE_API_CALL,
    CURLM_WAKEUP_FAILURE,
    CURLM_BAD_FUNCTION_ARGUMENT,
    CURLM_ABORTED_BY_CALLBACK,
    CURLM_UNRECOVERABLE_POLL,
    CURLM_LAST
}

// --- Option Types & Calculations ---
private enum CURLOPTTYPE_LONG = 0;
private enum CURLOPTTYPE_OBJECTPOINT = 10000;
private enum CURLOPTTYPE_FUNCTIONPOINT = 20000;
private enum CURLOPTTYPE_OFF_T = 30000;
private enum CURLOPTTYPE_BLOB = 40000;

private template MakeOpt(int type, int num)
{
    enum int MakeOpt = type + num;
}

// --- CURLoption ---
enum CURLoption : int
{
    CURLOPT_WRITEDATA = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 1),
    CURLOPT_URL = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 2),
    CURLOPT_PORT
        = MakeOpt!(CURLOPTTYPE_LONG, 3), CURLOPT_PROXY = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
                4), CURLOPT_USERPWD = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
                5), CURLOPT_PROXYUSERPWD = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
                6), CURLOPT_RANGE = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
                7), CURLOPT_ERRORBUFFER = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 10),
    CURLOPT_WRITEFUNCTION = MakeOpt!(CURLOPTTYPE_FUNCTIONPOINT,
            11),
    CURLOPT_READFUNCTION = MakeOpt!(CURLOPTTYPE_FUNCTIONPOINT,
            12),
    CURLOPT_TIMEOUT = MakeOpt!(CURLOPTTYPE_LONG,
            13),
    CURLOPT_INFILESIZE = MakeOpt!(CURLOPTTYPE_LONG, 14),
    CURLOPT_POSTFIELDS = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            15),
    CURLOPT_REFERER = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 16),
    CURLOPT_FTPPORT = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            17),
    CURLOPT_USERAGENT = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 18),
    CURLOPT_LOW_SPEED_LIMIT = MakeOpt!(CURLOPTTYPE_LONG,
            19),
    CURLOPT_LOW_SPEED_TIME = MakeOpt!(CURLOPTTYPE_LONG, 20),
    CURLOPT_RESUME_FROM = MakeOpt!(CURLOPTTYPE_LONG,
            21),
    CURLOPT_COOKIE = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 22),
    CURLOPT_HTTPHEADER = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            23),
    CURLOPT_SSLCERT = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 25),
    CURLOPT_KEYPASSWD = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            26),
    CURLOPT_READDATA = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 9),
    CURLOPT_HEADERDATA = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            29),
    CURLOPT_CUSTOMREQUEST = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 36),
    CURLOPT_POSTQUOTE = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            39),
    CURLOPT_VERBOSE = MakeOpt!(CURLOPTTYPE_LONG, 41),
    CURLOPT_HEADER = MakeOpt!(CURLOPTTYPE_LONG, 42),
    CURLOPT_NOPROGRESS = MakeOpt!(CURLOPTTYPE_LONG, 43),
    CURLOPT_NOBODY = MakeOpt!(CURLOPTTYPE_LONG, 44),
    CURLOPT_FAILONERROR
        = MakeOpt!(CURLOPTTYPE_LONG, 45), CURLOPT_UPLOAD = MakeOpt!(CURLOPTTYPE_LONG,
                46), CURLOPT_POST = MakeOpt!(CURLOPTTYPE_LONG,
                47), CURLOPT_FOLLOWLOCATION = MakeOpt!(CURLOPTTYPE_LONG, 52),
    CURLOPT_POSTFIELDSIZE = MakeOpt!(CURLOPTTYPE_LONG,
            60),
    CURLOPT_SSL_VERIFYPEER = MakeOpt!(CURLOPTTYPE_LONG, 64),
    CURLOPT_CAINFO = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            65),
    CURLOPT_MAXREDIRS = MakeOpt!(CURLOPTTYPE_LONG, 68),
    CURLOPT_HEADERFUNCTION = MakeOpt!(CURLOPTTYPE_FUNCTIONPOINT,
            79),
    CURLOPT_HTTPGET = MakeOpt!(CURLOPTTYPE_LONG, 80),
    CURLOPT_SSL_VERIFYHOST = MakeOpt!(CURLOPTTYPE_LONG, 81),
    CURLOPT_COOKIEJAR = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 82),
    CURLOPT_HTTP_VERSION = MakeOpt!(CURLOPTTYPE_LONG, 84),
    CURLOPT_ACCEPT_ENCODING = MakeOpt!(
            CURLOPTTYPE_OBJECTPOINT, 102),
    CURLOPT_CAPATH = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            97),
    CURLOPT_NOSIGNAL = MakeOpt!(CURLOPTTYPE_LONG,
            99),
    CURLOPT_BUFFERSIZE = MakeOpt!(CURLOPTTYPE_LONG, 98),
    CURLOPT_POSTFIELDSIZE_LARGE = MakeOpt!(CURLOPTTYPE_OFF_T,
            120),
    CURLOPT_TIMEOUT_MS = MakeOpt!(CURLOPTTYPE_LONG, 155),
    CURLOPT_CONNECTTIMEOUT_MS = MakeOpt!(CURLOPTTYPE_LONG,
            156),
    CURLOPT_POSTREDIR = MakeOpt!(CURLOPTTYPE_LONG, 161),
    CURLOPT_PIPEWAIT = MakeOpt!(CURLOPTTYPE_LONG, 237),
    CURLOPT_XFERINFOFUNCTION = MakeOpt!(CURLOPTTYPE_FUNCTIONPOINT, 219),
    CURLOPT_XFERINFODATA = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 57),
    CURLOPT_ALTSVC = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            287),
    CURLOPT_ALTSVC_CTRL = MakeOpt!(CURLOPTTYPE_LONG, 286),
    CURLOPT_QUICK_EXIT = MakeOpt!(CURLOPTTYPE_LONG,
            322),
    CURLOPT_CAINFO_BLOB = MakeOpt!(CURLOPTTYPE_BLOB, 309),
    CURLOPT_DEBUGFUNCTION = MakeOpt!(CURLOPTTYPE_FUNCTIONPOINT,
            94),
    CURLOPT_DEBUGDATA = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 95),
    CURLOPT_PROTOCOLS_STR = MakeOpt!(CURLOPTTYPE_OBJECTPOINT,
            318),
    CURLOPT_REDIR_PROTOCOLS_STR = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 319),
}

// --- CURLMoption ---
enum CURLMoption : int
{
    CURLMOPT_PIPELINING = 3,
    CURLMOPT_MAXCONNECTS = 6,
    CURLMOPT_MAX_HOST_CONNECTIONS = 7,
    CURLMOPT_MAX_TOTAL_CONNECTIONS = 13,
    CURLMOPT_MAX_CONCURRENT_STREAMS = 16,
    CURLMOPT_PUSHFUNCTION = MakeOpt!(CURLOPTTYPE_FUNCTIONPOINT, 14),
    CURLMOPT_PUSHDATA = MakeOpt!(CURLOPTTYPE_OBJECTPOINT, 15),
}

// --- Pipelining bitmask for CURLMOPT_PIPELINING ---
enum long CURLPIPE_NOTHING = 0L;
enum long CURLPIPE_HTTP1 = 1L;
enum long CURLPIPE_MULTIPLEX = 2L;

// --- Alt-Svc bitmask for CURLOPT_ALTSVC_CTRL ---
enum long CURLALTSVC_READONLYFILE = 1L << 2;
enum long CURLALTSVC_H1 = 1L << 3;
enum long CURLALTSVC_H2 = 1L << 4;
enum long CURLALTSVC_H3 = 1L << 5;

// --- HTTP Version constants for CURLOPT_HTTP_VERSION ---
enum long CURL_HTTP_VERSION_NONE = 0L;
enum long CURL_HTTP_VERSION_1_0 = 1L;
enum long CURL_HTTP_VERSION_1_1 = 2L;
enum long CURL_HTTP_VERSION_2_0 = 3L;
enum long CURL_HTTP_VERSION_2TLS = 4L;
enum long CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE = 5L;
enum long CURL_HTTP_VERSION_2 = CURL_HTTP_VERSION_2_0;

// HTTP/3 options guarded by HaveCurlHttp3 per plan spec
version (HaveCurlHttp3)
{
    enum long CURL_HTTP_VERSION_3 = 30L;
    enum long CURL_HTTP_VERSION_3ONLY = 31L;
}

// --- CURLINFO ---
private enum CURLINFO_STRING = 0x100000;
private enum CURLINFO_LONG = 0x200000;
private enum CURLINFO_DOUBLE = 0x300000;
private enum CURLINFO_SLIST = 0x400000;
private enum CURLINFO_OFF_T = 0x600000;

enum CURLINFO : int
{
    CURLINFO_NONE = 0,
    CURLINFO_EFFECTIVE_URL = CURLINFO_STRING + 1,
    CURLINFO_RESPONSE_CODE = CURLINFO_LONG + 2,
    CURLINFO_TOTAL_TIME = CURLINFO_DOUBLE + 3,
    CURLINFO_NAMELOOKUP_TIME = CURLINFO_DOUBLE + 4,
    CURLINFO_CONNECT_TIME = CURLINFO_DOUBLE + 5,
    CURLINFO_PRETRANSFER_TIME = CURLINFO_DOUBLE + 6,
    CURLINFO_SIZE_UPLOAD = CURLINFO_DOUBLE + 7,
    CURLINFO_SIZE_DOWNLOAD = CURLINFO_DOUBLE + 8,
    CURLINFO_SPEED_DOWNLOAD = CURLINFO_DOUBLE + 9,
    CURLINFO_SPEED_UPLOAD = CURLINFO_DOUBLE + 10,
    CURLINFO_HEADER_SIZE = CURLINFO_LONG + 11,
    CURLINFO_REQUEST_SIZE = CURLINFO_LONG + 12,
    CURLINFO_SSL_VERIFYRESULT = CURLINFO_LONG + 13,
    CURLINFO_CONTENT_LENGTH_DOWNLOAD
        = CURLINFO_DOUBLE + 15, CURLINFO_CONTENT_LENGTH_UPLOAD = CURLINFO_DOUBLE + 16,
    CURLINFO_CONTENT_TYPE = CURLINFO_STRING + 18,
    CURLINFO_REDIRECT_TIME = CURLINFO_DOUBLE + 19,
    CURLINFO_REDIRECT_COUNT = CURLINFO_LONG + 20,
    CURLINFO_HTTP_CONNECTCODE = CURLINFO_LONG + 22,
    CURLINFO_NUM_CONNECTS = CURLINFO_LONG + 26,
    CURLINFO_REDIRECT_URL = CURLINFO_STRING + 31,
    CURLINFO_PRIMARY_IP = CURLINFO_STRING + 32,
    CURLINFO_HTTP_VERSION = CURLINFO_LONG + 46,
    CURLINFO_TOTAL_TIME_T = CURLINFO_OFF_T + 50,
}

// --- Pause states ---
enum int CURLPAUSE_RECV = 1;
enum int CURLPAUSE_RECV_CONT = 0;
enum int CURLPAUSE_SEND = 4;
enum int CURLPAUSE_SEND_CONT = 0;
enum int CURLPAUSE_ALL = 5;
enum int CURLPAUSE_CONT = 0;

// --- Version bit constants (CURL_VERSION_*) ---
enum int CURL_VERSION_IPV6 = 1 << 0;
enum int CURL_VERSION_KERBEROS4 = 1 << 1;
enum int CURL_VERSION_SSL = 1 << 2;
enum int CURL_VERSION_LIBZ = 1 << 3;
enum int CURL_VERSION_NTLM = 1 << 4;
enum int CURL_VERSION_GSSNEGOTIATE = 1 << 5;
enum int CURL_VERSION_DEBUG = 1 << 6;
enum int CURL_VERSION_ASYNCHDNS = 1 << 7;
enum int CURL_VERSION_SPNEGO = 1 << 8;
enum int CURL_VERSION_LARGEFILE = 1 << 9;
enum int CURL_VERSION_IDN = 1 << 10;
enum int CURL_VERSION_SSPI = 1 << 11;
enum int CURL_VERSION_CONV = 1 << 12;
enum int CURL_VERSION_CURLDEBUG = 1 << 13;
enum int CURL_VERSION_TLSAUTH_SRP = 1 << 14;
enum int CURL_VERSION_NTLM_WB = 1 << 15;
enum int CURL_VERSION_HTTP2 = 1 << 16;
enum int CURL_VERSION_GSSAPI = 1 << 17;
enum int CURL_VERSION_KERBEROS5 = 1 << 18;
enum int CURL_VERSION_UNIX_SOCKETS = 1 << 19;
enum int CURL_VERSION_PSL = 1 << 20;
enum int CURL_VERSION_HTTPS_PROXY = 1 << 21;
enum int CURL_VERSION_MULTI_SSL = 1 << 22;
enum int CURL_VERSION_BROTLI = 1 << 23;
enum int CURL_VERSION_ALTSVC = 1 << 24;
enum int CURL_VERSION_HTTP3 = 1 << 25;
enum int CURL_VERSION_ZSTD = 1 << 26;
enum int CURL_VERSION_UNICODE = 1 << 27;
enum int CURL_VERSION_HSTS = 1 << 28;
enum int CURL_VERSION_GSASL = 1 << 29;
enum int CURL_VERSION_THREADSAFE = 1 << 30;

// --- Version age & info struct ---
enum CURLversion : int
{
    CURLVERSION_FIRST = 0,
    CURLVERSION_SECOND,
    CURLVERSION_THIRD,
    CURLVERSION_FOURTH,
    CURLVERSION_FIFTH,
    CURLVERSION_SIXTH,
    CURLVERSION_SEVENTH,
    CURLVERSION_EIGHTH,
    CURLVERSION_NINTH,
    CURLVERSION_TENTH,
    CURLVERSION_ELEVENTH,
    CURLVERSION_TWELFTH,
    CURLVERSION_LAST
}

enum CURLVERSION_NOW = CURLversion.CURLVERSION_TWELFTH;

struct curl_version_info_data
{
    CURLversion age;
    const(char)* version_;
    uint version_num;
    const(char)* host;
    int features;
    const(char)* ssl_version;
    c_long ssl_version_num;
    const(char)* libz_version;
    const(char*)* protocols;
    const(char)* ares;
    int ares_num;
    const(char)* libidn;
    int iconv_ver_num;
    const(char)* libssh_version;
    uint brotli_ver_num;
    const(char)* brotli_version;
    uint nghttp2_ver_num;
    const(char)* nghttp2_version;
    const(char)* quic_version;
    const(char)* cainfo;
    const(char)* capath;
    uint zstd_ver_num;
    const(char)* zstd_version;
    const(char)* hyper_version;
    const(char)* gsasl_version;
    const(char*)* feature_names;
    const(char)* rtmp_version;
}

// --- Slist structure ---
struct curl_slist
{
    char* data;
    curl_slist* next;
}

// --- Waitfd structure for multi ---
struct curl_waitfd
{
    curl_socket_t fd;
    short events;
    short revents;
}

enum short CURL_WAIT_POLLIN = 0x0001;
enum short CURL_WAIT_POLLPRI = 0x0002;
enum short CURL_WAIT_POLLOUT = 0x0004;

// --- CURLMsg structure for multi ---
enum CURLMSG : int
{
    CURLMSG_NONE = 0,
    CURLMSG_DONE = 1,
    CURLMSG_LAST
}

struct CURLMsg
{
    CURLMSG msg;
    CURL* easy_handle;
    union _data
    {
        void* whatever;
        CURLcode result;
    }

    _data data;
}

// --- Callback signatures ---
alias curl_write_callback = size_t function(char* ptr, size_t size, size_t nmemb, void* userdata) @nogc nothrow;
alias curl_read_callback = size_t function(char* buffer, size_t size, size_t nitems, void* userdata) @nogc nothrow;
alias curl_header_callback = size_t function(char* buffer, size_t size,
        size_t nitems, void* userdata) @nogc nothrow;
alias curl_xferinfo_callback = int function(void* clientp, curl_off_t dltotal,
        curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) @nogc nothrow;

// --- Real extern(C) function declarations linking against libcurl.so ---
extern (C) @system @nogc nothrow:

// Global functions
CURLcode curl_global_init(c_long flags);
void curl_global_cleanup();
CURLcode curl_global_init_mem(c_long flags, void* function(size_t size) rmalloc,
        void function(void* ptr) rfree, void* function(void* ptr, size_t size) rrealloc,
        char* function(const(char)* str) rstrdup, void* function(size_t nmemb, size_t size) rcalloc);

// Version functions
const(char)* curl_version();
curl_version_info_data* curl_version_info(CURLversion stamp);

// Easy functions
CURL* curl_easy_init();
CURLcode curl_easy_setopt(CURL* curl, CURLoption option, ...);
CURLcode curl_easy_perform(CURL* curl);
void curl_easy_cleanup(CURL* curl);
void curl_easy_reset(CURL* curl);
CURL* curl_easy_duphandle(CURL* curl);
CURLcode curl_easy_getinfo(CURL* curl, CURLINFO info, ...);
const(char)* curl_easy_strerror(CURLcode error);
char* curl_easy_escape(CURL* handle, const(char)* str, int length);
char* curl_easy_unescape(CURL* handle, const(char)* str, int length, int* outlength);
CURLcode curl_easy_pause(CURL* handle, int bitmask);
CURLcode curl_easy_upkeep(CURL* handle);

// Multi functions
CURLM* curl_multi_init();
CURLMcode curl_multi_add_handle(CURLM* multi_handle, CURL* curl_handle);
CURLMcode curl_multi_remove_handle(CURLM* multi_handle, CURL* curl_handle);
CURLMcode curl_multi_perform(CURLM* multi_handle, int* running_handles);
CURLMcode curl_multi_wait(CURLM* multi_handle, curl_waitfd* extra_fds,
        uint extra_nfds, int timeout_ms, int* ret);
CURLMcode curl_multi_poll(CURLM* multi_handle, curl_waitfd* extra_fds,
        uint extra_nfds, int timeout_ms, int* ret);
CURLMcode curl_multi_cleanup(CURLM* multi_handle);
CURLMsg* curl_multi_info_read(CURLM* multi_handle, int* msgs_in_queue);
const(char)* curl_multi_strerror(CURLMcode error);
CURLMcode curl_multi_setopt(CURLM* multi_handle, CURLMoption option, ...);
CURLMcode curl_multi_assign(CURLM* multi_handle, curl_socket_t sockfd, void* sockptr);
CURLMcode curl_multi_wakeup(CURLM* multi_handle);

// Memory & slist functions
void curl_free(void* p);
curl_slist* curl_slist_append(curl_slist* list, const(char)* string);
void curl_slist_free_all(curl_slist* list);

// --- Unittests for c_bind ---

// Spec: curl_version(3) and curl_global_init(3) man pages
/// Example:
/// ---
/// import slate.http.c_bind;
/// curl_global_init(CURL_GLOBAL_DEFAULT);
/// scope(exit) curl_global_cleanup();
/// const(char)* v = curl_version();
/// assert(v !is null);
/// ---
unittest
{
    // Test link smoke and basic global lifecycle
    auto initCode = curl_global_init(CURL_GLOBAL_DEFAULT);
    assert(initCode == CURLcode.CURLE_OK, "curl_global_init must succeed");
    scope (exit)
        curl_global_cleanup();

    const(char)* verStr = curl_version();
    assert(verStr !is null, "curl_version must return a non-null string");
    import core.stdc.string : strlen;

    assert(strlen(verStr) > 0, "curl_version string must be non-empty");

    auto info = curl_version_info(CURLVERSION_NOW);
    assert(info !is null, "curl_version_info must return valid data");
    assert(info.version_ !is null, "info.version_ must be non-null");
    assert(info.age >= CURLversion.CURLVERSION_FOURTH,
            "age should be at least fourth for modern curl");
}

// Spec: curl_easy_init(3), curl_easy_reset(3), curl_easy_cleanup(3) man pages
/// Example:
/// ---
/// import slate.http.c_bind;
/// CURL* handle = curl_easy_init();
/// if (handle !is null) {
///     scope(exit) curl_easy_cleanup(handle);
///     curl_easy_reset(handle);
/// }
/// ---
unittest
{
    auto handle = curl_easy_init();
    assert(handle !is null, "curl_easy_init must create a valid handle");
    scope (exit)
        curl_easy_cleanup(handle);

    curl_easy_reset(handle);

    // Smoke test strerror
    const(char)* okMsg = curl_easy_strerror(CURLcode.CURLE_OK);
    assert(okMsg !is null, "curl_easy_strerror(CURLE_OK) must return a message");

    auto optRes = curl_easy_setopt(handle, CURLoption.CURLOPT_QUICK_EXIT, 1L);
    assert(optRes == CURLcode.CURLE_OK, "Setting CURLOPT_QUICK_EXIT on easy handle must succeed");
}

// Spec: curl_multi_init(3), curl_multi_cleanup(3), curl_multi_strerror(3) man pages
/// Example:
/// ---
/// import slate.http.c_bind;
/// CURLM* multi = curl_multi_init();
/// if (multi !is null) {
///     scope(exit) curl_multi_cleanup(multi);
///     curl_multi_setopt(multi, CURLMoption.CURLMOPT_MAX_TOTAL_CONNECTIONS, 10L);
/// }
/// ---
unittest
{
    auto multi = curl_multi_init();
    assert(multi !is null, "curl_multi_init must create a valid multi handle");
    scope (exit)
        curl_multi_cleanup(multi);

    const(char)* okMsg = curl_multi_strerror(CURLMcode.CURLM_OK);
    assert(okMsg !is null, "curl_multi_strerror(CURLM_OK) must return a message");

    auto mOptRes = curl_multi_setopt(multi, CURLMoption.CURLMOPT_MAX_TOTAL_CONNECTIONS, 10L);
    assert(mOptRes == CURLMcode.CURLM_OK, "Setting CURLMOPT_MAX_TOTAL_CONNECTIONS must succeed");
}
