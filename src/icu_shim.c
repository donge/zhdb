/*
 * POSIX/glibc ICU exports versioned symbols (u_getUnicodeVersion_74), while the
 * Zig code declares the unsuffixed C names. This shim includes the real ICU
 * headers, so the version renaming is applied by the headers, and exposes the
 * stable names that the Zig side links against.
 *
 * Only built on Linux; macOS uses the system libicucore, which exports the
 * unsuffixed symbols directly.
 */
#include <stdint.h>
#include <unicode/uchar.h>
#include <unicode/unorm2.h>
#include <unicode/uversion.h>

const UNormalizer2 *zhdb_unorm2_getNFCInstance(int32_t *err) {
    return unorm2_getNFCInstance((UErrorCode *)err);
}

const UNormalizer2 *zhdb_unorm2_getNFDInstance(int32_t *err) {
    return unorm2_getNFDInstance((UErrorCode *)err);
}

const UNormalizer2 *zhdb_unorm2_getNFKCInstance(int32_t *err) {
    return unorm2_getNFKCInstance((UErrorCode *)err);
}

const UNormalizer2 *zhdb_unorm2_getNFKDInstance(int32_t *err) {
    return unorm2_getNFKDInstance((UErrorCode *)err);
}

int32_t zhdb_unorm2_normalize(const UNormalizer2 *n2, const uint16_t *src, int32_t len,
                              uint16_t *dest, int32_t cap, int32_t *err) {
    return unorm2_normalize(n2, src, len, dest, cap, (UErrorCode *)err);
}

int8_t zhdb_unorm2_isNormalized(const UNormalizer2 *n2, const uint16_t *src, int32_t len,
                                int32_t *err) {
    return (int8_t)unorm2_isNormalized(n2, src, len, (UErrorCode *)err);
}

int8_t zhdb_u_isdefined(int32_t c) {
    return (int8_t)u_isdefined((UChar32)c);
}

void zhdb_u_getUnicodeVersion(uint8_t v[4]) {
    UVersionInfo info;
    u_getUnicodeVersion(info);
    for (int i = 0; i < 4; i++) v[i] = info[i];
}
