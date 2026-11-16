/* Link check for the static libssl/libcrypto: known-answer crypto tests, then a TLS 1.3
 * handshake that verifies the server chain against the system CA store.
 * usage: openssl_smoke [host] [port]   (host "-" skips the network part) */
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

static int failures;

static void check(int ok, const char *what)
{
    printf("%-34s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static void hex(const unsigned char *in, size_t n, char *out)
{
    for (size_t i = 0; i < n; i++)
        sprintf(out + 2 * i, "%02x", in[i]);
}

static void crypto_checks(void)
{
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int mdlen = 0;
    char h[2 * EVP_MAX_MD_SIZE + 1];

    EVP_Digest("abc", 3, md, &mdlen, EVP_sha256(), NULL);
    hex(md, mdlen, h);
    check(!strcmp(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "SHA-256 abc");

    /* GCM spec test case 2: zero key, zero IV, one zero block. */
    unsigned char key[16] = {0}, iv[12] = {0}, pt[16] = {0}, ct[16], tag[16];
    int len = 0, total = 0;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, key, iv);
    EVP_EncryptUpdate(ctx, ct, &len, pt, sizeof pt);
    total = len;
    EVP_EncryptFinal_ex(ctx, ct + total, &len);
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag);
    EVP_CIPHER_CTX_free(ctx);
    hex(ct, 16, h);
    check(!strcmp(h, "0388dace60b6a392f328c2b971b2fe78"), "AES-128-GCM ciphertext");
    hex(tag, 16, h);
    check(!strcmp(h, "ab6e47d42cec13bdf53a67b21257bddf"), "AES-128-GCM tag");

    /* RFC 8439 2.8.2 would need its full vector; a round trip still exercises the asm path. */
    unsigned char k32[32] = {1}, n12[12] = {2}, msg[40] = "chacha20-poly1305 round trip", enc[40], dec[40], t2[16];
    ctx = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(ctx, EVP_chacha20_poly1305(), NULL, k32, n12);
    EVP_EncryptUpdate(ctx, enc, &len, msg, sizeof msg);
    EVP_EncryptFinal_ex(ctx, enc + len, &len);
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, 16, t2);
    EVP_CIPHER_CTX_free(ctx);
    ctx = EVP_CIPHER_CTX_new();
    EVP_DecryptInit_ex(ctx, EVP_chacha20_poly1305(), NULL, k32, n12);
    EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, 16, t2);
    EVP_DecryptUpdate(ctx, dec, &len, enc, sizeof enc);
    int fin = EVP_DecryptFinal_ex(ctx, dec + len, &len);
    EVP_CIPHER_CTX_free(ctx);
    check(fin > 0 && !memcmp(dec, msg, sizeof msg), "ChaCha20-Poly1305 round trip");

    EVP_PKEY *pk = EVP_EC_gen("P-256");
    unsigned char sig[128];
    size_t siglen = sizeof sig;
    EVP_MD_CTX *mc = EVP_MD_CTX_new();
    EVP_DigestSignInit(mc, NULL, EVP_sha256(), NULL, pk);
    EVP_DigestSign(mc, sig, &siglen, (const unsigned char *)"msg", 3);
    EVP_MD_CTX_free(mc);
    mc = EVP_MD_CTX_new();
    EVP_DigestVerifyInit(mc, NULL, EVP_sha256(), NULL, pk);
    check(EVP_DigestVerify(mc, sig, siglen, (const unsigned char *)"msg", 3) == 1, "ECDSA P-256 sign/verify");
    EVP_MD_CTX_free(mc);
    EVP_PKEY_free(pk);
}

static int tls_check(const char *host, const char *port)
{
    struct addrinfo hints = {.ai_socktype = SOCK_STREAM}, *res;
    if (getaddrinfo(host, port, &hints, &res)) {
        printf("resolve %s failed\n", host);
        return 1;
    }
    int fd = socket(res->ai_family, res->ai_socktype, 0);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen)) {
        printf("connect %s:%s failed\n", host, port);
        return 1;
    }
    freeaddrinfo(res);

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    check(SSL_CTX_set_default_verify_paths(ctx) == 1, "default verify paths");
    printf("default CA file: %s, dir: %s\n", X509_get_default_cert_file(), X509_get_default_cert_dir());
    SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);
    SSL_set_tlsext_host_name(ssl, host);
    SSL_set1_host(ssl, host);
    int rc = SSL_connect(ssl);
    if (rc != 1)
        ERR_print_errors_fp(stdout);
    check(rc == 1, "TLS handshake");
    check(SSL_get_verify_result(ssl) == X509_V_OK, "certificate chain verified");
    printf("%s, %s, verify: %s\n", SSL_get_version(ssl), SSL_get_cipher_name(ssl),
           X509_verify_cert_error_string(SSL_get_verify_result(ssl)));
    check(SSL_version(ssl) == TLS1_3_VERSION, "negotiated TLS 1.3");

    char req[256], buf[64];
    snprintf(req, sizeof req, "HEAD / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", host);
    SSL_write(ssl, req, (int)strlen(req));
    int n = SSL_read(ssl, buf, sizeof buf - 1);
    check(n > 4 && !strncmp(buf, "HTTP/", 5), "HTTP response over TLS");
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);
    return 0;
}

int main(int argc, char **argv)
{
    printf("%s\n", OpenSSL_version(OPENSSL_VERSION));
    crypto_checks();
    const char *host = argc > 1 ? argv[1] : "example.com";
    if (strcmp(host, "-") && tls_check(host, argc > 2 ? argv[2] : "443"))
        failures++;
    return failures ? 1 : 0;
}
