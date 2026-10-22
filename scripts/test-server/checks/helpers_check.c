/* Checks the two standalone helpers nothing else exercises, on whatever
 * Mac this runs on (CI: macOS 27 and 26, Apple Silicon and Intel): password
 * hashing, which is the one use of the bundled libxcrypt, and photo
 * resizing through ImageIO. Each hash is checked by recomputing it from
 * its own salt — with libcrypto for the digests and PBKDF2, with libxcrypt
 * itself for the crypt(3) family — and a wrong password must not match. */
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <crypt.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ldapstudio.h"

static int failures;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "PASS" : "FAIL", what);
  if (!ok) failures++;
}

static const char *const PASSWORD = "correct horse battery staple";

/* Base64 without the padding guesswork of EVP_DecodeBlock. */
static unsigned char *b64(const char *s, int *len) {
  size_t n = strlen(s);
  unsigned char *out = malloc(n);
  EVP_ENCODE_CTX *ctx = EVP_ENCODE_CTX_new();
  int l = 0, fin = 0;
  EVP_DecodeInit(ctx);
  if (EVP_DecodeUpdate(ctx, out, &l, (const unsigned char *)s, (int)n) < 0 ||
      EVP_DecodeFinal(ctx, out + l, &fin) != 1) {
    l = -1;
  } else {
    l += fin;
  }
  EVP_ENCODE_CTX_free(ctx);
  *len = l;
  return out;
}

static char *hash(LSPasswordScheme scheme, const char *plaintext) {
  LSError err = {0};
  char *out = NULL;
  if (ls_hash_password(plaintext, scheme, &out, &err) != 0) return NULL;
  return out;
}

/* {TAG}base64(digest(pw)) or, salted, {TAG}base64(digest(pw||salt)||salt). */
static int digest_matches(const char *h, const char *tag, const EVP_MD *md, int salted,
                          const char *plaintext) {
  size_t tl = strlen(tag);
  if (strncmp(h, tag, tl) != 0) return 0;
  int len;
  unsigned char *raw = b64(h + tl, &len);
  int dl = EVP_MD_get_size(md);
  int ok = 0;
  if (len == (salted ? dl + 8 : dl)) {
    unsigned char *buf = malloc(strlen(plaintext) + 8);
    memcpy(buf, plaintext, strlen(plaintext));
    if (salted) memcpy(buf + strlen(plaintext), raw + dl, 8);
    unsigned char d[EVP_MAX_MD_SIZE];
    unsigned int dlen = 0;
    EVP_Digest(buf, strlen(plaintext) + (salted ? 8 : 0), d, &dlen, md, NULL);
    ok = dlen == (unsigned)dl && memcmp(d, raw, (size_t)dl) == 0;
    free(buf);
  }
  free(raw);
  return ok;
}

/* {PBKDF2-SHA512}iterations$base64(salt)$base64(key) */
static int pbkdf2_matches(const char *h, const char *plaintext) {
  const char *tag = "{PBKDF2-SHA512}";
  if (strncmp(h, tag, strlen(tag)) != 0) return 0;
  char *copy = strdup(h + strlen(tag));
  char *iter = strtok(copy, "$"), *salt_b64 = strtok(NULL, "$"), *key_b64 = strtok(NULL, "$");
  int ok = 0;
  if (iter && salt_b64 && key_b64 && atoi(iter) >= 10000) {
    int sl, kl;
    unsigned char *salt = b64(salt_b64, &sl), *key = b64(key_b64, &kl);
    unsigned char derived[64];
    if (sl == 16 && kl == 64 &&
        PKCS5_PBKDF2_HMAC(plaintext, (int)strlen(plaintext), salt, sl, atoi(iter), EVP_sha512(),
                          64, derived) == 1) {
      ok = memcmp(derived, key, 64) == 0;
    }
    free(salt);
    free(key);
  }
  free(copy);
  return ok;
}

/* {CRYPT}setting... — libxcrypt reproduces it from the hash's own setting. */
static int crypt_matches(const char *h, const char *prefix, const char *plaintext) {
  if (strncmp(h, "{CRYPT}", 7) != 0 || strncmp(h + 7, prefix, strlen(prefix)) != 0) return 0;
  struct crypt_data data;
  memset(&data, 0, sizeof data);
  const char *again = crypt_r(plaintext, h + 7, &data);
  return again && strcmp(again, h + 7) == 0;
}

static void check_hashes(void) {
  struct {
    LSPasswordScheme scheme;
    const char *name;
  } schemes[] = {
      {LS_PBKDF2_SHA512, "PBKDF2-SHA512"}, {LS_MD5, "MD5"},
      {LS_SHA1, "SHA"}, {LS_SMD5, "SMD5"},
      {LS_SSHA, "SSHA"}, {LS_UNIX_CRYPT, "CRYPT (DES)"},
      {LS_MD5_CRYPT, "CRYPT $1$"}, {LS_SHA256_CRYPT, "CRYPT $5$"},
      {LS_SHA512_CRYPT, "CRYPT $6$"},
  };
  for (size_t i = 0; i < sizeof schemes / sizeof *schemes; i++) {
    char what[128];
    char *h = hash(schemes[i].scheme, PASSWORD);
    char *wrong = hash(schemes[i].scheme, "wrong");
    snprintf(what, sizeof what, "hash %s: produced", schemes[i].name);
    check(h != NULL && wrong != NULL, what);
    if (!h || !wrong) continue;
    int ok = 0, mismatch = 0;
    switch (schemes[i].scheme) {
      case LS_PBKDF2_SHA512: ok = pbkdf2_matches(h, PASSWORD); mismatch = !pbkdf2_matches(h, "wrong"); break;
      case LS_MD5: ok = digest_matches(h, "{MD5}", EVP_md5(), 0, PASSWORD); mismatch = strcmp(h, wrong) != 0; break;
      case LS_SHA1: ok = digest_matches(h, "{SHA}", EVP_sha1(), 0, PASSWORD); mismatch = strcmp(h, wrong) != 0; break;
      case LS_SMD5: ok = digest_matches(h, "{SMD5}", EVP_md5(), 1, PASSWORD); mismatch = !digest_matches(h, "{SMD5}", EVP_md5(), 1, "wrong"); break;
      case LS_SSHA: ok = digest_matches(h, "{SSHA}", EVP_sha1(), 1, PASSWORD); mismatch = !digest_matches(h, "{SSHA}", EVP_sha1(), 1, "wrong"); break;
      case LS_UNIX_CRYPT: ok = crypt_matches(h, "", PASSWORD) && strlen(h + 7) == 13; mismatch = !crypt_matches(h, "", "wrong"); break;
      case LS_MD5_CRYPT: ok = crypt_matches(h, "$1$", PASSWORD); mismatch = !crypt_matches(h, "$1$", "wrong"); break;
      case LS_SHA256_CRYPT: ok = crypt_matches(h, "$5$", PASSWORD); mismatch = !crypt_matches(h, "$5$", "wrong"); break;
      case LS_SHA512_CRYPT: ok = crypt_matches(h, "$6$", PASSWORD); mismatch = !crypt_matches(h, "$6$", "wrong"); break;
    }
    snprintf(what, sizeof what, "hash %s: verifies from its own salt: %.24s…", schemes[i].name, h);
    check(ok, what);
    snprintf(what, sizeof what, "hash %s: a wrong password doesn't", schemes[i].name);
    check(mismatch, what);
    ls_string_free(h);
    ls_string_free(wrong);
  }
  /* Salted schemes must not repeat. */
  char *a = hash(LS_SSHA, PASSWORD), *b = hash(LS_SSHA, PASSWORD);
  check(a && b && strcmp(a, b) != 0, "hash SSHA: a fresh salt every time");
  ls_string_free(a);
  ls_string_free(b);
}

/* A 640x400 PNG with a colour gradient, resized: 300x300 JPEG, cropped square. */
static void check_photo(void) {
  char path[] = "/tmp/ldap-studio-photo-XXXXXX.png";
  int fd = mkstemps(path, 4);
  check(fd >= 0, "photo: temp file");
  if (fd < 0) return;
  close(fd);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(NULL, 640, 400, 8, 0, cs, kCGImageAlphaPremultipliedLast);
  CGContextSetRGBFillColor(ctx, 0.2, 0.4, 0.9, 1);
  CGContextFillRect(ctx, CGRectMake(0, 0, 640, 400));
  CGContextSetRGBFillColor(ctx, 0.9, 0.3, 0.1, 1);
  CGContextFillRect(ctx, CGRectMake(120, 0, 400, 400));
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CFStringRef cfpath = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfpath, kCFURLPOSIXPathStyle, false);
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
  CGImageDestinationAddImage(dst, img, NULL);
  check(CGImageDestinationFinalize(dst), "photo: wrote a 640x400 PNG");
  CFRelease(dst);
  CFRelease(url);
  CFRelease(cfpath);
  CGImageRelease(img);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);

  LSError err = {0};
  char *out = NULL;
  int rc = ls_resize_photo_to_base64(path, &out, &err);
  check(rc == 0 && out != NULL, "photo: resized");
  if (rc == 0 && out) {
    int len;
    unsigned char *jpeg = b64(out, &len);
    CFDataRef data = CFDataCreate(NULL, jpeg, len);
    CGImageSourceRef src = CGImageSourceCreateWithData(data, NULL);
    CFStringRef type = src ? CGImageSourceGetType(src) : NULL;
    check(type && CFStringCompare(type, CFSTR("public.jpeg"), 0) == kCFCompareEqualTo, "photo: result is a JPEG");
    CGImageRef result = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    check(result && CGImageGetWidth(result) == 300 && CGImageGetHeight(result) == 300, "photo: 300x300");
    if (result) CGImageRelease(result);
    if (src) CFRelease(src);
    CFRelease(data);
    free(jpeg);
    ls_string_free(out);
  }
  unlink(path);
  check(ls_resize_photo_to_base64("/nonexistent.png", &out, &err) != 0, "photo: a missing file is an error");
}

int main(void) {
  check_hashes();
  check_photo();
  printf(failures == 0 ? "HELPER CHECKS PASSED\n" : "%d HELPER CHECKS FAILED\n", failures);
  return failures == 0 ? 0 : 1;
}
