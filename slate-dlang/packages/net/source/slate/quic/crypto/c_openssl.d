module slate.quic.crypto.c_openssl;

/**
 * Low-level C FFI declarations for OpenSSL 3.5 libcrypto and libssl.
 *
 * Package-private to slate.quic to prevent raw C pointer leakage.
 */
package(slate.quic):

extern (C) @system @nogc nothrow:

// --- OpenSSL Version ---
ulong OpenSSL_version_num();
const(char)* OpenSSL_version(int type);

// --- EVP Message Digest ---
struct EVP_MD;
const(EVP_MD)* EVP_sha256();
const(EVP_MD)* EVP_sha384();

// --- EVP Cipher ---
struct EVP_CIPHER;
struct EVP_CIPHER_CTX;

EVP_CIPHER_CTX* EVP_CIPHER_CTX_new();
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX* ctx);
int EVP_CIPHER_CTX_reset(EVP_CIPHER_CTX* ctx);
int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX* ctx, int type, int arg, void* ptr);
int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX* ctx, int pad);

const(EVP_CIPHER)* EVP_aes_128_gcm();
const(EVP_CIPHER)* EVP_aes_256_gcm();
const(EVP_CIPHER)* EVP_chacha20_poly1305();
const(EVP_CIPHER)* EVP_aes_128_ecb();
const(EVP_CIPHER)* EVP_aes_256_ecb();
const(EVP_CIPHER)* EVP_chacha20();

int EVP_EncryptInit_ex(EVP_CIPHER_CTX* ctx, const(EVP_CIPHER)* cipher,
        void* impl_, const(ubyte)* key, const(ubyte)* iv);
int EVP_EncryptUpdate(EVP_CIPHER_CTX* ctx, ubyte* out_, int* outl, const(ubyte)* in_, int inl);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX* ctx, ubyte* out_, int* outl);

int EVP_DecryptInit_ex(EVP_CIPHER_CTX* ctx, const(EVP_CIPHER)* cipher,
        void* impl_, const(ubyte)* key, const(ubyte)* iv);
int EVP_DecryptUpdate(EVP_CIPHER_CTX* ctx, ubyte* out_, int* outl, const(ubyte)* in_, int inl);
int EVP_DecryptFinal_ex(EVP_CIPHER_CTX* ctx, ubyte* out_, int* outl);

int EVP_CipherInit_ex(EVP_CIPHER_CTX* ctx, const(EVP_CIPHER)* cipher,
        void* impl_, const(ubyte)* key, const(ubyte)* iv, int enc);

enum int EVP_CTRL_AEAD_SET_IVLEN = 0x9;
enum int EVP_CTRL_AEAD_GET_TAG = 0x10;
enum int EVP_CTRL_AEAD_SET_TAG = 0x11;

// --- HMAC (for HKDF) ---
ubyte* HMAC(const(EVP_MD)* evp_md, const(void)* key, int key_len,
        const(ubyte)* d, size_t n, ubyte* md, uint* md_len);

// --- Random Bytes ---
int RAND_bytes(ubyte* buf, int num);

// --- TLS / SSL ---
struct SSL_CTX;
struct SSL;
struct SSL_METHOD;
struct SSL_CIPHER;

const(SSL_METHOD)* TLS_method();
const(SSL_METHOD)* TLS_server_method();
const(SSL_METHOD)* TLS_client_method();

SSL_CTX* SSL_CTX_new(const(SSL_METHOD)* method);
void SSL_CTX_free(SSL_CTX* ctx);
long SSL_CTX_ctrl(SSL_CTX* ctx, int cmd, long larg, void* parg);
long SSL_ctrl(SSL* s, int cmd, long larg, void* parg);

enum int SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
enum int SSL_CTRL_SET_MAX_PROTO_VERSION = 124;
enum int TLS1_3_VERSION = 0x0304;

enum int SSL_FILETYPE_PEM = 1;
int SSL_CTX_use_certificate_file(SSL_CTX* ctx, const(char)* file, int type);
int SSL_CTX_use_certificate_chain_file(SSL_CTX* ctx, const(char)* file);
int SSL_CTX_use_PrivateKey_file(SSL_CTX* ctx, const(char)* file, int type);

// ALPN callback signature
alias SSL_CTX_alpn_select_cb_fn = int function(SSL* s, const(ubyte)** out_,
        ubyte* outlen, const(ubyte)* in_, uint inlen, void* arg) @nogc nothrow;

void SSL_CTX_set_alpn_select_cb(SSL_CTX* ctx, SSL_CTX_alpn_select_cb_fn cb, void* arg);
int SSL_CTX_set_alpn_protos(SSL_CTX* ctx, const(ubyte)* protos, uint protos_len);
int SSL_set_alpn_protos(SSL* s, const(ubyte)* protos, uint protos_len);
void SSL_get0_alpn_selected(const(SSL)* s, const(ubyte)** data, uint* len);

enum int SSL_TLSEXT_ERR_OK = 0;
enum int SSL_TLSEXT_ERR_ALERT_FATAL = 2;
enum int SSL_TLSEXT_ERR_NOACK = 3;

SSL* SSL_new(SSL_CTX* ctx);
void SSL_free(SSL* s);
void SSL_set_accept_state(SSL* s);
void SSL_set_connect_state(SSL* s);
int SSL_do_handshake(SSL* s);
int SSL_get_error(const(SSL)* s, int ret_code);

const(SSL_CIPHER)* SSL_get_current_cipher(const(SSL)* s);
uint SSL_CIPHER_get_protocol_id(const(SSL_CIPHER)* c);
uint SSL_CIPHER_get_id(const(SSL_CIPHER)* c);

// --- OpenSSL 3.5 QUIC TLS API ---
struct OSSL_DISPATCH
{
    int function_id;
    const(void)* fn;
}

enum : int
{
    OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_SEND = 2001,
    OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RECV_RCD = 2002,
    OSSL_FUNC_SSL_QUIC_TLS_CRYPTO_RELEASE_RCD = 2003,
    OSSL_FUNC_SSL_QUIC_TLS_YIELD_SECRET = 2004,
    OSSL_FUNC_SSL_QUIC_TLS_GOT_TRANSPORT_PARAMS = 2005,
    OSSL_FUNC_SSL_QUIC_TLS_ALERT = 2006,
}

enum : uint
{
    OSSL_RECORD_PROTECTION_LEVEL_NONE = 0,
    OSSL_RECORD_PROTECTION_LEVEL_EARLY = 1,
    OSSL_RECORD_PROTECTION_LEVEL_HANDSHAKE = 2,
    OSSL_RECORD_PROTECTION_LEVEL_APPLICATION = 3,
}

int SSL_set_quic_tls_cbs(SSL* s, const(OSSL_DISPATCH)* qtdis, void* arg);
int SSL_set_quic_tls_transport_params(SSL* s, const(ubyte)* params, size_t params_len);
int SSL_set_quic_tls_early_data_enabled(SSL* s, int enabled);
int SSL_CTX_set_ciphersuites(SSL_CTX* ctx, const(char)* str);

/// Example:
// Spec: OpenSSL 3.5 API and OpenSSL_version_num manual
@nogc unittest
{
    const ulong ver = OpenSSL_version_num();
    assert(ver >= 0x30500000L, "OpenSSL version must be >= 3.5.0");
}
