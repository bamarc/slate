module slate.h3.qpack;

/**
 * QPACK: Field Compression for HTTP/3 (RFC 9204) and Huffman Codec (RFC 7541 Appendix B).
 *
 * Implements the 99-entry Static Table (RFC 9204 Appendix A), N-bit prefixed integer codec,
 * canonical RFC 7541 Appendix B Huffman encoder/decoder with strict EOS and padding validation,
 * and field section encoder/decoder.
 */

public import slate.h3.error;

/**
 * A single HTTP/3 name-value header field.
 */
public struct H3HeaderField
{
    const(char)[] name;
    const(char)[] value;
}

/**
 * An entry in the QPACK Static Table (RFC 9204 Appendix A).
 */
public struct QpackStaticEntry
{
    string name;
    string value;
}

public enum size_t MAX_H3_HEADERS = 64;

public immutable QpackStaticEntry[99] QPACK_STATIC_TABLE = [
    QpackStaticEntry(":authority", ""), // 0
    QpackStaticEntry(":path", "/"), // 1
    QpackStaticEntry("age", "0"), // 2
    QpackStaticEntry("content-disposition", ""), // 3
    QpackStaticEntry("content-length", "0"), // 4
    QpackStaticEntry("cookie", ""), // 5
    QpackStaticEntry("date", ""), // 6
    QpackStaticEntry("etag", ""), // 7
    QpackStaticEntry("if-modified-since", ""), // 8
    QpackStaticEntry("if-none-match", ""), // 9
    QpackStaticEntry("last-modified", ""), // 10
    QpackStaticEntry("link", ""), // 11
    QpackStaticEntry("location", ""), // 12
    QpackStaticEntry("referer", ""), // 13
    QpackStaticEntry("set-cookie", ""), // 14
    QpackStaticEntry(":method", "CONNECT"), // 15
    QpackStaticEntry(":method", "DELETE"), // 16
    QpackStaticEntry(":method", "GET"), // 17
    QpackStaticEntry(":method", "HEAD"), // 18
    QpackStaticEntry(":method", "OPTIONS"), // 19
    QpackStaticEntry(":method", "POST"), // 20
    QpackStaticEntry(":method", "PUT"), // 21
    QpackStaticEntry(":scheme", "http"), // 22
    QpackStaticEntry(":scheme", "https"), // 23
    QpackStaticEntry(":status", "103"), // 24
    QpackStaticEntry(":status", "200"), // 25
    QpackStaticEntry(":status", "304"), // 26
    QpackStaticEntry(":status", "404"), // 27
    QpackStaticEntry(":status", "503"), // 28
    QpackStaticEntry("accept", "*/*"), // 29
    QpackStaticEntry("accept",
            "application/dns-message"), // 30
    QpackStaticEntry("accept-encoding",
            "gzip, deflate, br"), // 31
    QpackStaticEntry("accept-ranges", "bytes"), // 32
    QpackStaticEntry("access-control-allow-headers",
            "cache-control"), // 33
    QpackStaticEntry("access-control-allow-headers",
            "content-type"), // 34
    QpackStaticEntry("access-control-allow-origin",
            "*"), // 35
    QpackStaticEntry("cache-control", "max-age=0"), // 36
    QpackStaticEntry("cache-control",
            "max-age=2592000"), // 37
    QpackStaticEntry("cache-control",
            "max-age=604800"), // 38
    QpackStaticEntry("cache-control", "no-cache"), // 39
    QpackStaticEntry("cache-control",
            "no-store"), // 40
    QpackStaticEntry("cache-control", "public, max-age=31536000"), // 41
    QpackStaticEntry("content-encoding", "br"), // 42
    QpackStaticEntry("content-encoding",
            "gzip"), // 43
    QpackStaticEntry("content-type", "application/dns-message"), // 44
    QpackStaticEntry("content-type", "application/javascript"), // 45
    QpackStaticEntry("content-type", "application/json"), // 46
    QpackStaticEntry("content-type", "application/x-www-form-urlencoded"), // 47
    QpackStaticEntry("content-type", "image/gif"), // 48
    QpackStaticEntry("content-type",
            "image/jpeg"), // 49
    QpackStaticEntry("content-type", "image/png"), // 50
    QpackStaticEntry("content-type",
            "text/css"), // 51
    QpackStaticEntry("content-type", "text/html; charset=utf-8"), // 52
    QpackStaticEntry("content-type", "text/plain"), // 53
    QpackStaticEntry("content-type",
            "text/plain;charset=utf-8"), // 54
    QpackStaticEntry("range", "bytes=0-"), // 55
    QpackStaticEntry("strict-transport-security",
            "max-age=31536000"), // 56
    QpackStaticEntry("strict-transport-security",
            "max-age=31536000; includesubdomains"), // 57
    QpackStaticEntry("strict-transport-security",
            "max-age=31536000; includesubdomains; preload"), // 58
    QpackStaticEntry("vary",
            "accept-encoding"), // 59
    QpackStaticEntry("vary", "origin"), // 60
    QpackStaticEntry("x-content-type-options",
            "nosniff"), // 61
    QpackStaticEntry("x-xss-protection", "1; mode=block"), // 62
    QpackStaticEntry(":status", "100"), // 63
    QpackStaticEntry(":status", "204"), // 64
    QpackStaticEntry(":status", "206"), // 65
    QpackStaticEntry(":status", "302"), // 66
    QpackStaticEntry(":status", "400"), // 67
    QpackStaticEntry(":status", "403"), // 68
    QpackStaticEntry(":status", "421"), // 69
    QpackStaticEntry(":status", "425"), // 70
    QpackStaticEntry(":status", "500"), // 71
    QpackStaticEntry("accept-language",
            ""), // 72
    QpackStaticEntry("access-control-allow-credentials", "FALSE"), // 73
    QpackStaticEntry("access-control-allow-credentials", "TRUE"), // 74
    QpackStaticEntry("access-control-allow-headers", "*"), // 75
    QpackStaticEntry("access-control-allow-methods", "get"), // 76
    QpackStaticEntry("access-control-allow-methods",
            "get, post, options"), // 77
    QpackStaticEntry("access-control-allow-methods", "options"), // 78
    QpackStaticEntry("access-control-expose-headers", "content-length"), // 79
    QpackStaticEntry("access-control-request-headers", "content-type"), // 80
    QpackStaticEntry("access-control-request-method", "get"), // 81
    QpackStaticEntry("access-control-request-method", "post"), // 82
    QpackStaticEntry("alt-svc", "clear"), // 83
    QpackStaticEntry("authorization",
            ""), // 84
    QpackStaticEntry("content-security-policy",
            "script-src 'none'; object-src 'none'; base-uri 'none'"), // 85
    QpackStaticEntry("early-data", "1"), // 86
    QpackStaticEntry("expect-ct", ""), // 87
    QpackStaticEntry("forwarded", ""), // 88
    QpackStaticEntry("if-range", ""), // 89
    QpackStaticEntry("origin", ""), // 90
    QpackStaticEntry("purpose", "prefetch"), // 91
    QpackStaticEntry("server", ""), // 92
    QpackStaticEntry("timing-allow-origin",
            "*"), // 93
    QpackStaticEntry("upgrade-insecure-requests", "1"), // 94
    QpackStaticEntry("user-agent", ""), // 95
    QpackStaticEntry("x-forwarded-for", ""), // 96
    QpackStaticEntry("x-frame-options",
            "deny"), // 97
    QpackStaticEntry("x-frame-options", "sameorigin"), // 98
];

/**
 * Searches the QPACK static table for an exact match of both name and value.
 * Returns the index (0..98) or -1 if no exact match is found.
 */
public ptrdiff_t findStaticExact(const(char)[] name, const(char)[] value) @safe pure nothrow @nogc
{
    foreach (i, const ref entry; QPACK_STATIC_TABLE)
    {
        if (entry.name == name && entry.value == value)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

/**
 * Searches the QPACK static table for a match of name only.
 * Returns the first matching index (0..98) or -1 if not found.
 */
public ptrdiff_t findStaticName(const(char)[] name) @safe pure nothrow @nogc
{
    foreach (i, const ref entry; QPACK_STATIC_TABLE)
    {
        if (entry.name == name)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

/**
 * Encodes an integer using the N-bit prefix encoding defined in RFC 7541 Section 5.1 / RFC 9204 Section 4.1.1.
 */
public bool encodePrefixedInt(ulong value, ubyte prefixBits, ubyte prefixPattern,
        ubyte[] outBuf, ref size_t offset) @safe pure nothrow @nogc
{
    if (prefixBits == 0 || prefixBits > 8)
        return false;
    if (offset >= outBuf.length)
        return false;

    const size_t startOffset = offset;
    const ulong maxPrefix = (1UL << prefixBits) - 1UL;
    if (value < maxPrefix)
    {
        outBuf[offset++] = cast(ubyte)(prefixPattern | cast(ubyte) value);
        return true;
    }

    outBuf[offset++] = cast(ubyte)(prefixPattern | cast(ubyte) maxPrefix);
    ulong rem = value - maxPrefix;
    while (rem >= 128)
    {
        if (offset >= outBuf.length)
        {
            offset = startOffset;
            return false;
        }
        outBuf[offset++] = cast(ubyte)((rem & 0x7F) | 0x80);
        rem >>= 7;
    }
    if (offset >= outBuf.length)
    {
        offset = startOffset;
        return false;
    }
    outBuf[offset++] = cast(ubyte) rem;
    return true;
}

/**
 * Decodes an integer using the N-bit prefix encoding defined in RFC 7541 Section 5.1 / RFC 9204 Section 4.1.1.
 * Guards against 64-bit integer overflow and excessive continuation bytes.
 */
public bool decodePrefixedInt(const(ubyte)[] input, ref size_t offset,
        ubyte prefixBits, out ulong result) @safe pure nothrow @nogc
{
    if (prefixBits == 0 || prefixBits > 8)
        return false;
    if (offset >= input.length)
        return false;

    const ulong maxPrefix = (1UL << prefixBits) - 1UL;
    const ubyte first = input[offset++];
    const ulong prefixVal = cast(ulong)(first & maxPrefix);

    if (prefixVal < maxPrefix)
    {
        result = prefixVal;
        return true;
    }

    ulong val = prefixVal;
    uint shift = 0;
    while (true)
    {
        if (offset >= input.length)
            return false;
        const ubyte b = input[offset++];
        const ulong chunk = cast(ulong)(b & 0x7F);

        if (shift > 63 || (shift == 63 && chunk > 1))
            return false;
        const ulong add = chunk << shift;
        if (ulong.max - val < add)
            return false;

        val += add;
        shift += 7;
        if ((b & 0x80) == 0)
            break;
    }

    result = val;
    return true;
}

private struct HuffmanCode
{
    uint code;
    ubyte bits;
}

private immutable HuffmanCode[257] HUFFMAN_CODES = [
    HuffmanCode(0x1ff8, 13), // 0
    HuffmanCode(0x7fffd8, 23), // 1
    HuffmanCode(0xfffffe2, 28), // 2
    HuffmanCode(0xfffffe3, 28), // 3
    HuffmanCode(0xfffffe4, 28), // 4
    HuffmanCode(0xfffffe5, 28), // 5
    HuffmanCode(0xfffffe6, 28), // 6
    HuffmanCode(0xfffffe7, 28), // 7
    HuffmanCode(0xfffffe8, 28), // 8
    HuffmanCode(0xffffea, 24), // 9
    HuffmanCode(0x3ffffffc, 30), // 10
    HuffmanCode(0xfffffe9, 28), // 11
    HuffmanCode(0xfffffea, 28), // 12
    HuffmanCode(0x3ffffffd, 30), // 13
    HuffmanCode(0xfffffeb, 28), // 14
    HuffmanCode(0xfffffec, 28), // 15
    HuffmanCode(0xfffffed, 28), // 16
    HuffmanCode(0xfffffee, 28), // 17
    HuffmanCode(0xfffffef, 28), // 18
    HuffmanCode(0xffffff0, 28), // 19
    HuffmanCode(0xffffff1, 28), // 20
    HuffmanCode(0xffffff2, 28), // 21
    HuffmanCode(0x3ffffffe, 30), // 22
    HuffmanCode(0xffffff3, 28), // 23
    HuffmanCode(0xffffff4, 28), // 24
    HuffmanCode(0xffffff5, 28), // 25
    HuffmanCode(0xffffff6, 28), // 26
    HuffmanCode(0xffffff7, 28), // 27
    HuffmanCode(0xffffff8, 28), // 28
    HuffmanCode(0xffffff9, 28), // 29
    HuffmanCode(0xffffffa, 28), // 30
    HuffmanCode(0xffffffb, 28), // 31
    HuffmanCode(0x14, 6), // 32
    HuffmanCode(0x3f8, 10), // 33
    HuffmanCode(0x3f9, 10), // 34
    HuffmanCode(0xffa, 12), // 35
    HuffmanCode(0x1ff9, 13), // 36
    HuffmanCode(0x15, 6), // 37
    HuffmanCode(0xf8, 8), // 38
    HuffmanCode(0x7fa, 11), // 39
    HuffmanCode(0x3fa, 10), // 40
    HuffmanCode(0x3fb, 10), // 41
    HuffmanCode(0xf9, 8), // 42
    HuffmanCode(0x7fb, 11), // 43
    HuffmanCode(0xfa, 8), // 44
    HuffmanCode(0x16, 6), // 45
    HuffmanCode(0x17, 6), // 46
    HuffmanCode(0x18, 6), // 47
    HuffmanCode(0x0, 5), // 48
    HuffmanCode(0x1, 5), // 49
    HuffmanCode(0x2, 5), // 50
    HuffmanCode(0x19, 6), // 51
    HuffmanCode(0x1a, 6), // 52
    HuffmanCode(0x1b, 6), // 53
    HuffmanCode(0x1c, 6), // 54
    HuffmanCode(0x1d, 6), // 55
    HuffmanCode(0x1e, 6), // 56
    HuffmanCode(0x1f, 6), // 57
    HuffmanCode(0x5c, 7), // 58
    HuffmanCode(0xfb, 8), // 59
    HuffmanCode(0x7ffc, 15), // 60
    HuffmanCode(0x20, 6), // 61
    HuffmanCode(0xffb, 12), // 62
    HuffmanCode(0x3fc, 10), // 63
    HuffmanCode(0x1ffa, 13), // 64
    HuffmanCode(0x21, 6), // 65
    HuffmanCode(0x5d, 7), // 66
    HuffmanCode(0x5e, 7), // 67
    HuffmanCode(0x5f, 7), // 68
    HuffmanCode(0x60, 7), // 69
    HuffmanCode(0x61, 7), // 70
    HuffmanCode(0x62, 7), // 71
    HuffmanCode(0x63, 7), // 72
    HuffmanCode(0x64, 7), // 73
    HuffmanCode(0x65, 7), // 74
    HuffmanCode(0x66, 7), // 75
    HuffmanCode(0x67, 7), // 76
    HuffmanCode(0x68, 7), // 77
    HuffmanCode(0x69, 7), // 78
    HuffmanCode(0x6a, 7), // 79
    HuffmanCode(0x6b, 7), // 80
    HuffmanCode(0x6c, 7), // 81
    HuffmanCode(0x6d, 7), // 82
    HuffmanCode(0x6e, 7), // 83
    HuffmanCode(0x6f, 7), // 84
    HuffmanCode(0x70, 7), // 85
    HuffmanCode(0x71, 7), // 86
    HuffmanCode(0x72, 7), // 87
    HuffmanCode(0xfc, 8), // 88
    HuffmanCode(0x73, 7), // 89
    HuffmanCode(0xfd, 8), // 90
    HuffmanCode(0x1ffb, 13), // 91
    HuffmanCode(0x7fff0, 19), // 92
    HuffmanCode(0x1ffc, 13), // 93
    HuffmanCode(0x3ffc, 14), // 94
    HuffmanCode(0x22, 6), // 95
    HuffmanCode(0x7ffd, 15), // 96
    HuffmanCode(0x3, 5), // 97
    HuffmanCode(0x23, 6), // 98
    HuffmanCode(0x4, 5), // 99
    HuffmanCode(0x24, 6), // 100
    HuffmanCode(0x5, 5), // 101
    HuffmanCode(0x25, 6), // 102
    HuffmanCode(0x26, 6), // 103
    HuffmanCode(0x27, 6), // 104
    HuffmanCode(0x6, 5), // 105
    HuffmanCode(0x74, 7), // 106
    HuffmanCode(0x75, 7), // 107
    HuffmanCode(0x28, 6), // 108
    HuffmanCode(0x29, 6), // 109
    HuffmanCode(0x2a, 6), // 110
    HuffmanCode(0x7, 5), // 111
    HuffmanCode(0x2b, 6), // 112
    HuffmanCode(0x76, 7), // 113
    HuffmanCode(0x2c, 6), // 114
    HuffmanCode(0x8, 5), // 115
    HuffmanCode(0x9, 5), // 116
    HuffmanCode(0x2d, 6), // 117
    HuffmanCode(0x77, 7), // 118
    HuffmanCode(0x78, 7), // 119
    HuffmanCode(0x79, 7), // 120
    HuffmanCode(0x7a, 7), // 121
    HuffmanCode(0x7b, 7), // 122
    HuffmanCode(0x7ffe, 15), // 123
    HuffmanCode(0x7fc, 11), // 124
    HuffmanCode(0x3ffd, 14), // 125
    HuffmanCode(0x1ffd, 13), // 126
    HuffmanCode(0xffffffc, 28), // 127
    HuffmanCode(0xfffe6, 20), // 128
    HuffmanCode(0x3fffd2, 22), // 129
    HuffmanCode(0xfffe7, 20), // 130
    HuffmanCode(0xfffe8, 20), // 131
    HuffmanCode(0x3fffd3, 22), // 132
    HuffmanCode(0x3fffd4, 22), // 133
    HuffmanCode(0x3fffd5, 22), // 134
    HuffmanCode(0x7fffd9, 23), // 135
    HuffmanCode(0x3fffd6, 22), // 136
    HuffmanCode(0x7fffda, 23), // 137
    HuffmanCode(0x7fffdb, 23), // 138
    HuffmanCode(0x7fffdc, 23), // 139
    HuffmanCode(0x7fffdd, 23), // 140
    HuffmanCode(0x7fffde, 23), // 141
    HuffmanCode(0xffffeb, 24), // 142
    HuffmanCode(0x7fffdf, 23), // 143
    HuffmanCode(0xffffec, 24), // 144
    HuffmanCode(0xffffed, 24), // 145
    HuffmanCode(0x3fffd7, 22), // 146
    HuffmanCode(0x7fffe0, 23), // 147
    HuffmanCode(0xffffee, 24), // 148
    HuffmanCode(0x7fffe1, 23), // 149
    HuffmanCode(0x7fffe2, 23), // 150
    HuffmanCode(0x7fffe3, 23), // 151
    HuffmanCode(0x7fffe4, 23), // 152
    HuffmanCode(0x1fffdc, 21), // 153
    HuffmanCode(0x3fffd8, 22), // 154
    HuffmanCode(0x7fffe5, 23), // 155
    HuffmanCode(0x3fffd9, 22), // 156
    HuffmanCode(0x7fffe6, 23), // 157
    HuffmanCode(0x7fffe7, 23), // 158
    HuffmanCode(0xffffef, 24), // 159
    HuffmanCode(0x3fffda, 22), // 160
    HuffmanCode(0x1fffdd, 21), // 161
    HuffmanCode(0xfffe9, 20), // 162
    HuffmanCode(0x3fffdb, 22), // 163
    HuffmanCode(0x3fffdc, 22), // 164
    HuffmanCode(0x7fffe8, 23), // 165
    HuffmanCode(0x7fffe9, 23), // 166
    HuffmanCode(0x1fffde, 21), // 167
    HuffmanCode(0x7fffea, 23), // 168
    HuffmanCode(0x3fffdd, 22), // 169
    HuffmanCode(0x3fffde, 22), // 170
    HuffmanCode(0xfffff0, 24), // 171
    HuffmanCode(0x1fffdf, 21), // 172
    HuffmanCode(0x3fffdf, 22), // 173
    HuffmanCode(0x7fffeb, 23), // 174
    HuffmanCode(0x7fffec, 23), // 175
    HuffmanCode(0x1fffe0, 21), // 176
    HuffmanCode(0x1fffe1, 21), // 177
    HuffmanCode(0x3fffe0, 22), // 178
    HuffmanCode(0x1fffe2, 21), // 179
    HuffmanCode(0x7fffed, 23), // 180
    HuffmanCode(0x3fffe1, 22), // 181
    HuffmanCode(0x7fffee, 23), // 182
    HuffmanCode(0x7fffef, 23), // 183
    HuffmanCode(0xfffea, 20), // 184
    HuffmanCode(0x3fffe2, 22), // 185
    HuffmanCode(0x3fffe3, 22), // 186
    HuffmanCode(0x3fffe4, 22), // 187
    HuffmanCode(0x7ffff0, 23), // 188
    HuffmanCode(0x3fffe5, 22), // 189
    HuffmanCode(0x3fffe6, 22), // 190
    HuffmanCode(0x7ffff1, 23), // 191
    HuffmanCode(0x3ffffe0, 26), // 192
    HuffmanCode(0x3ffffe1, 26), // 193
    HuffmanCode(0xfffeb, 20), // 194
    HuffmanCode(0x7fff1, 19), // 195
    HuffmanCode(0x3fffe7, 22), // 196
    HuffmanCode(0x7ffff2, 23), // 197
    HuffmanCode(0x3fffe8, 22), // 198
    HuffmanCode(0x1ffffec, 25), // 199
    HuffmanCode(0x3ffffe2, 26), // 200
    HuffmanCode(0x3ffffe3, 26), // 201
    HuffmanCode(0x3ffffe4, 26), // 202
    HuffmanCode(0x7ffffde, 27), // 203
    HuffmanCode(0x7ffffdf, 27), // 204
    HuffmanCode(0x3ffffe5, 26), // 205
    HuffmanCode(0xfffff1, 24), // 206
    HuffmanCode(0x1ffffed, 25), // 207
    HuffmanCode(0x7fff2, 19), // 208
    HuffmanCode(0x1fffe3, 21), // 209
    HuffmanCode(0x3ffffe6, 26), // 210
    HuffmanCode(0x7ffffe0, 27), // 211
    HuffmanCode(0x7ffffe1, 27), // 212
    HuffmanCode(0x3ffffe7, 26), // 213
    HuffmanCode(0x7ffffe2, 27), // 214
    HuffmanCode(0xfffff2, 24), // 215
    HuffmanCode(0x1fffe4, 21), // 216
    HuffmanCode(0x1fffe5, 21), // 217
    HuffmanCode(0x3ffffe8, 26), // 218
    HuffmanCode(0x3ffffe9, 26), // 219
    HuffmanCode(0xffffffd, 28), // 220
    HuffmanCode(0x7ffffe3, 27), // 221
    HuffmanCode(0x7ffffe4, 27), // 222
    HuffmanCode(0x7ffffe5, 27), // 223
    HuffmanCode(0xfffec, 20), // 224
    HuffmanCode(0xfffff3, 24), // 225
    HuffmanCode(0xfffed, 20), // 226
    HuffmanCode(0x1fffe6, 21), // 227
    HuffmanCode(0x3fffe9, 22), // 228
    HuffmanCode(0x1fffe7, 21), // 229
    HuffmanCode(0x1fffe8, 21), // 230
    HuffmanCode(0x7ffff3, 23), // 231
    HuffmanCode(0x3fffea, 22), // 232
    HuffmanCode(0x3fffeb, 22), // 233
    HuffmanCode(0x1ffffee, 25), // 234
    HuffmanCode(0x1ffffef, 25), // 235
    HuffmanCode(0xfffff4, 24), // 236
    HuffmanCode(0xfffff5, 24), // 237
    HuffmanCode(0x3ffffea, 26), // 238
    HuffmanCode(0x7ffff4, 23), // 239
    HuffmanCode(0x3ffffeb, 26), // 240
    HuffmanCode(0x7ffffe6, 27), // 241
    HuffmanCode(0x3ffffec, 26), // 242
    HuffmanCode(0x3ffffed, 26), // 243
    HuffmanCode(0x7ffffe7, 27), // 244
    HuffmanCode(0x7ffffe8, 27), // 245
    HuffmanCode(0x7ffffe9, 27), // 246
    HuffmanCode(0x7ffffea, 27), // 247
    HuffmanCode(0x7ffffeb, 27), // 248
    HuffmanCode(0xffffffe, 28), // 249
    HuffmanCode(0x7ffffec, 27), // 250
    HuffmanCode(0x7ffffed, 27), // 251
    HuffmanCode(0x7ffffee, 27), // 252
    HuffmanCode(0x7ffffef, 27), // 253
    HuffmanCode(0x7fffff0, 27), // 254
    HuffmanCode(0x3ffffee, 26), // 255
    HuffmanCode(0x3fffffff, 30), // 256
];

private struct HuffmanNode
{
    short left = -1;
    short right = -1;
    short symbol = -1;
}

private HuffmanNode[513] buildHuffmanTree() @safe pure nothrow @nogc
{
    HuffmanNode[513] tree;
    int nextNode = 1;
    foreach (sym; 0 .. 257)
    {
        const uint code = HUFFMAN_CODES[sym].code;
        const ubyte bits = HUFFMAN_CODES[sym].bits;
        int curr = 0;
        foreach_reverse (b; 0 .. bits)
        {
            const bool bit = (code & (1u << b)) != 0;
            if (bit)
            {
                if (tree[curr].right == -1)
                {
                    tree[curr].right = cast(short) nextNode;
                    nextNode++;
                }
                curr = tree[curr].right;
            }
            else
            {
                if (tree[curr].left == -1)
                {
                    tree[curr].left = cast(short) nextNode;
                    nextNode++;
                }
                curr = tree[curr].left;
            }
        }
        tree[curr].symbol = cast(short) sym;
    }
    return tree;
}

private immutable HuffmanNode[513] HUFFMAN_TREE = buildHuffmanTree();

/**
 * Calculates the exact byte length of str when encoded with RFC 7541 Huffman coding.
 */
public size_t huffmanEncodedLength(const(char)[] str) @safe pure nothrow @nogc
{
    size_t bits = 0;
    foreach (ch; cast(const(ubyte)[]) str)
    {
        bits += HUFFMAN_CODES[ch].bits;
    }
    return (bits + 7) / 8;
}

/**
 * Encodes str using RFC 7541 Appendix B Huffman code into outBuf starting at offset.
 * Appends EOS prefix padding (all 1s) up to byte boundary.
 */
public bool encodeHuffman(const(char)[] str, ubyte[] outBuf, ref size_t offset) @safe pure nothrow @nogc
{
    const size_t needed = huffmanEncodedLength(str);
    if (offset + needed > outBuf.length)
        return false;

    ulong bitBuffer = 0;
    ubyte bitsInBuffer = 0;

    foreach (ch; cast(const(ubyte)[]) str)
    {
        const HuffmanCode hc = HUFFMAN_CODES[ch];
        bitBuffer = (bitBuffer << hc.bits) | hc.code;
        bitsInBuffer += hc.bits;

        while (bitsInBuffer >= 8)
        {
            bitsInBuffer -= 8;
            outBuf[offset++] = cast(ubyte)(bitBuffer >> bitsInBuffer);
        }
    }

    if (bitsInBuffer > 0)
    {
        const ubyte padBits = cast(ubyte)(8 - bitsInBuffer);
        bitBuffer = (bitBuffer << padBits) | ((1u << padBits) - 1u);
        outBuf[offset++] = cast(ubyte) bitBuffer;
    }

    return true;
}

/**
 * Decodes RFC 7541 Appendix B Huffman-encoded data into outBuf.
 * Strictly verifies that EOS (symbol 256) is not in data, padding is at most 7 bits,
 * and padding bits are strictly all 1s (RFC 7541 Section 5.2 / RFC 9204 Section 4.1.2).
 */
public H3ErrorCode decodeHuffman(const(ubyte)[] input, char[] outBuf, out size_t outLen) @safe pure nothrow @nogc
{
    outLen = 0;
    int curr = 0;
    int bitsSinceSym = 0;
    bool allOnesSinceSym = true;

    foreach (b; input)
    {
        foreach_reverse (i; 0 .. 8)
        {
            const bool bit = (b & (1 << i)) != 0;
            bitsSinceSym++;
            if (!bit)
                allOnesSinceSym = false;

            curr = bit ? HUFFMAN_TREE[curr].right : HUFFMAN_TREE[curr].left;
            if (curr == -1)
                return H3ErrorCode.qpackDecompressionFailed;

            const short sym = HUFFMAN_TREE[curr].symbol;
            if (sym != -1)
            {
                if (sym == 256)
                    return H3ErrorCode.qpackDecompressionFailed; // EOS forbidden in encoded string
                if (outLen >= outBuf.length)
                    return H3ErrorCode.qpackDecompressionFailed; // Buffer overflow

                outBuf[outLen++] = cast(char) sym;
                curr = 0;
                bitsSinceSym = 0;
                allOnesSinceSym = true;
            }
        }
    }

    if (curr != 0)
    {
        if (bitsSinceSym > 7 || !allOnesSinceSym)
            return H3ErrorCode.qpackDecompressionFailed;
    }

    return H3ErrorCode.noError;
}

/**
 * Encodes a string literal according to RFC 9204 Section 4.1.2.
 */
private bool encodeStringLiteral(const(char)[] str, bool allowHuffman,
        ubyte[] outBuf, ref size_t offset) @safe pure nothrow @nogc
{
    const size_t rawLen = str.length;
    const size_t huffLen = allowHuffman ? huffmanEncodedLength(str) : rawLen + 1;
    const bool useHuff = allowHuffman && (huffLen < rawLen);

    if (useHuff)
    {
        if (!encodePrefixedInt(huffLen, 7, 0x80, outBuf, offset))
            return false;
        return encodeHuffman(str, outBuf, offset);
    }
    else
    {
        if (!encodePrefixedInt(rawLen, 7, 0x00, outBuf, offset))
            return false;
        if (offset + rawLen > outBuf.length)
            return false;
        outBuf[offset .. offset + rawLen] = cast(const(ubyte)[]) str[];
        offset += rawLen;
        return true;
    }
}

/**
 * Decodes a string literal according to RFC 9204 Section 4.1.2 into strBuffer.
 */
private H3ErrorCode decodeStringLiteral(const(ubyte)[] input, ref size_t inOffset,
        char[] strBuffer, ref size_t strBufUsed, out const(char)[] result) @safe pure nothrow @nogc
{
    if (inOffset >= input.length)
        return H3ErrorCode.qpackDecompressionFailed;

    const bool isHuff = (input[inOffset] & 0x80) != 0;
    ulong strLen = 0;
    if (!decodePrefixedInt(input, inOffset, 7, strLen))
        return H3ErrorCode.qpackDecompressionFailed;

    if (strLen > input.length - inOffset)
        return H3ErrorCode.qpackDecompressionFailed;

    const const(ubyte)[] strBytes = input[inOffset .. inOffset + cast(size_t) strLen];
    inOffset += cast(size_t) strLen;

    if (isHuff)
    {
        size_t decodedLen = 0;
        H3ErrorCode err = decodeHuffman(strBytes, strBuffer[strBufUsed .. $], decodedLen);
        if (err != H3ErrorCode.noError)
            return err;
        result = strBuffer[strBufUsed .. strBufUsed + decodedLen];
        strBufUsed += decodedLen;
        return H3ErrorCode.noError;
    }
    else
    {
        if (strBufUsed + cast(size_t) strLen > strBuffer.length)
            return H3ErrorCode.qpackDecompressionFailed;
        strBuffer[strBufUsed .. strBufUsed + cast(size_t) strLen] = cast(const(char)[]) strBytes[];
        result = strBuffer[strBufUsed .. strBufUsed + cast(size_t) strLen];
        strBufUsed += cast(size_t) strLen;
        return H3ErrorCode.noError;
    }
}

/**
 * Encodes an array of HTTP/3 header fields into a QPACK field section (RFC 9204 Section 4.5).
 * Uses static table exact matches, static table name matches, and literal fields with optional Huffman encoding.
 */
public size_t encodeQpackFieldSection(const(H3HeaderField)[] headers,
        ubyte[] outBuf, bool useHuffman = true) @safe pure nothrow @nogc
{
    if (outBuf.length < 2)
        return 0;

    size_t offset = 0;
    // Section prefix: Required Insert Count = 0, Delta Base = 0 (RFC 9204 Section 4.5.1)
    outBuf[offset++] = 0x00;
    outBuf[offset++] = 0x00;

    foreach (const ref h; headers)
    {
        const ptrdiff_t exactIdx = findStaticExact(h.name, h.value);
        if (exactIdx >= 0)
        {
            // Indexed Field Line (Static Table): 1 1 Index (6+)
            if (!encodePrefixedInt(cast(ulong) exactIdx, 6, 0xC0, outBuf, offset))
                return 0;
            continue;
        }

        const ptrdiff_t nameIdx = findStaticName(h.name);
        if (nameIdx >= 0)
        {
            // Literal Field Line With Name Reference (Static Table): 0 1 N T Index (4+), T=1, N=0
            if (!encodePrefixedInt(cast(ulong) nameIdx, 4, 0x50, outBuf, offset))
                return 0;
            if (!encodeStringLiteral(h.value, useHuffman, outBuf, offset))
                return 0;
            continue;
        }

        // Literal Field Line With Literal Name: 0 0 1 N H NameLen (3+), N=0
        const size_t rawNameLen = h.name.length;
        const size_t huffNameLen = useHuffman ? huffmanEncodedLength(h.name) : rawNameLen + 1;
        const bool useNameHuff = useHuffman && (huffNameLen < rawNameLen);

        if (useNameHuff)
        {
            if (!encodePrefixedInt(huffNameLen, 3, 0x28, outBuf, offset))
                return 0;
            if (!encodeHuffman(h.name, outBuf, offset))
                return 0;
        }
        else
        {
            if (!encodePrefixedInt(rawNameLen, 3, 0x20, outBuf, offset))
                return 0;
            if (offset + rawNameLen > outBuf.length)
                return 0;
            outBuf[offset .. offset + rawNameLen] = cast(const(ubyte)[]) h.name[];
            offset += rawNameLen;
        }

        if (!encodeStringLiteral(h.value, useHuffman, outBuf, offset))
            return 0;
    }

    return offset;
}

/**
 * Decodes a QPACK field section into outHeaders and backing strBuffer (RFC 9204 Section 4.5).
 * Validates static indices, rejects dynamic table references when table capacity is 0,
 * enforces maxFieldSectionSize and MAX_H3_HEADERS limits.
 */
public H3ErrorCode decodeQpackFieldSection(const(ubyte)[] input, H3HeaderField[] outHeaders,
        out size_t headerCount, char[] strBuffer, out size_t strBufUsed,
        ulong maxFieldSectionSize = ulong.max) @safe pure nothrow @nogc
{
    headerCount = 0;
    strBufUsed = 0;
    ulong totalSectionSize = 0;

    if (input.length < 2)
        return H3ErrorCode.qpackDecompressionFailed;

    size_t inOffset = 0;

    // 1. Required Insert Count (8+ prefix)
    ulong reqInsertCount = 0;
    if (!decodePrefixedInt(input, inOffset, 8, reqInsertCount))
        return H3ErrorCode.qpackDecompressionFailed;
    if (reqInsertCount != 0)
        return H3ErrorCode.qpackDecompressionFailed; // Dynamic table capacity is 0

    // 2. Base (Sign bit + 7+ prefix)
    if (inOffset >= input.length)
        return H3ErrorCode.qpackDecompressionFailed;
    const bool signBit = (input[inOffset] & 0x80) != 0;
    ulong deltaBase = 0;
    if (!decodePrefixedInt(input, inOffset, 7, deltaBase))
        return H3ErrorCode.qpackDecompressionFailed;
    // Per RFC 9204 Section 4.5.1.2: Base MUST NOT be negative.
    // When Sign bit is 1, Delta Base must be strictly less than Required Insert Count.
    // Since reqInsertCount == 0, signBit == 1 is unconditionally invalid.
    if (signBit || (signBit && reqInsertCount <= deltaBase))
        return H3ErrorCode.qpackDecompressionFailed;

    // 3. Header Representations
    while (inOffset < input.length)
    {
        if (headerCount >= outHeaders.length || headerCount >= MAX_H3_HEADERS)
            return H3ErrorCode.qpackDecompressionFailed;

        const ubyte first = input[inOffset];
        const(char)[] name;
        const(char)[] value;

        if ((first & 0x80) != 0)
        {
            // Section 4.5.2: Indexed Field Line: 1 T Index (6+)
            const bool isStatic = (first & 0x40) != 0;
            if (!isStatic)
                return H3ErrorCode.qpackDecompressionFailed; // Dynamic table not supported

            ulong index = 0;
            if (!decodePrefixedInt(input, inOffset, 6, index))
                return H3ErrorCode.qpackDecompressionFailed;
            if (index >= QPACK_STATIC_TABLE.length)
                return H3ErrorCode.qpackDecompressionFailed;

            name = QPACK_STATIC_TABLE[cast(size_t) index].name;
            value = QPACK_STATIC_TABLE[cast(size_t) index].value;
        }
        else if ((first & 0x40) != 0)
        {
            // Section 4.5.4: Literal Field Line With Name Reference: 0 1 N T Index (4+)
            const bool isStatic = (first & 0x10) != 0;
            if (!isStatic)
                return H3ErrorCode.qpackDecompressionFailed; // Dynamic table not supported

            ulong nameIndex = 0;
            if (!decodePrefixedInt(input, inOffset, 4, nameIndex))
                return H3ErrorCode.qpackDecompressionFailed;
            if (nameIndex >= QPACK_STATIC_TABLE.length)
                return H3ErrorCode.qpackDecompressionFailed;

            name = QPACK_STATIC_TABLE[cast(size_t) nameIndex].name;
            H3ErrorCode err = decodeStringLiteral(input, inOffset, strBuffer, strBufUsed, value);
            if (err != H3ErrorCode.noError)
                return err;
        }
        else if ((first & 0x20) != 0)
        {
            // Section 4.5.6: Literal Field Line With Literal Name: 0 0 1 N H NameLen (3+)
            const bool nameIsHuff = (first & 0x08) != 0;
            ulong nameLen = 0;
            if (!decodePrefixedInt(input, inOffset, 3, nameLen))
                return H3ErrorCode.qpackDecompressionFailed;

            if (nameLen > input.length - inOffset)
                return H3ErrorCode.qpackDecompressionFailed;
            const const(ubyte)[] nameBytes = input[inOffset .. inOffset + cast(size_t) nameLen];
            inOffset += cast(size_t) nameLen;

            if (nameIsHuff)
            {
                size_t decLen = 0;
                H3ErrorCode err = decodeHuffman(nameBytes, strBuffer[strBufUsed .. $], decLen);
                if (err != H3ErrorCode.noError)
                    return err;
                name = strBuffer[strBufUsed .. strBufUsed + decLen];
                strBufUsed += decLen;
            }
            else
            {
                if (strBufUsed + cast(size_t) nameLen > strBuffer.length)
                    return H3ErrorCode.qpackDecompressionFailed;
                strBuffer[strBufUsed .. strBufUsed + cast(size_t) nameLen] = cast(const(char)[]) nameBytes[];
                name = strBuffer[strBufUsed .. strBufUsed + cast(size_t) nameLen];
                strBufUsed += cast(size_t) nameLen;
            }

            H3ErrorCode err = decodeStringLiteral(input, inOffset, strBuffer, strBufUsed, value);
            if (err != H3ErrorCode.noError)
                return err;
        }
        else
        {
            // Section 4.5.3 (0 0 0 1 ...) or 4.5.5 (0 0 0 0 ...): Post-Base dynamic table reference
            return H3ErrorCode.qpackDecompressionFailed;
        }

        // Accumulate RFC 7541 / RFC 9114 field size: name.length + value.length + 32
        const ulong entrySize = name.length + value.length + 32;
        if (ulong.max - totalSectionSize < entrySize)
            return H3ErrorCode.qpackDecompressionFailed;
        totalSectionSize += entrySize;
        if (totalSectionSize > maxFieldSectionSize)
            return H3ErrorCode.qpackDecompressionFailed;

        outHeaders[headerCount++] = H3HeaderField(name, value);
    }

    return H3ErrorCode.noError;
}

/// Example:
// Spec: RFC 7541 Section 5.1, RFC 9204 Section 4.1.1 - Prefixed Integer Encoding and Overflow Protection (covers Scenario T1, U1, U3, E1)
@nogc unittest
{
    ubyte[32] buf;
    size_t offset = 0;

    // 5-bit prefix: value 10 < 31
    assert(encodePrefixedInt(10, 5, 0x00, buf[], offset));
    assert(offset == 1);
    assert(buf[0] == 10);

    size_t decOffset = 0;
    ulong decVal = 0;
    assert(decodePrefixedInt(buf[0 .. offset], decOffset, 5, decVal));
    assert(decVal == 10);
    assert(decOffset == 1);

    // 5-bit prefix: value 1337 >= 31
    offset = 0;
    assert(encodePrefixedInt(1337, 5, 0x20, buf[], offset));
    decOffset = 0;
    assert(decodePrefixedInt(buf[0 .. offset], decOffset, 5, decVal));
    assert(decVal == 1337);

    // 8-bit prefix: value 42
    offset = 0;
    assert(encodePrefixedInt(42, 8, 0x00, buf[], offset));
    decOffset = 0;
    assert(decodePrefixedInt(buf[0 .. offset], decOffset, 8, decVal));
    assert(decVal == 42);

    // 6-bit prefix: value 98 (QPACK static table max index)
    offset = 0;
    assert(encodePrefixedInt(98, 6, 0xC0, buf[], offset));
    decOffset = 0;
    assert(decodePrefixedInt(buf[0 .. offset], decOffset, 6, decVal));
    assert(decVal == 98);

    // Integer overflow detection: 11 bytes of 0xFF
    ubyte[12] overflowBuf = [
        0x1F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F
    ];
    decOffset = 0;
    assert(!decodePrefixedInt(overflowBuf[], decOffset, 5, decVal));
}

/// Example:
// Spec: RFC 9204 Appendix A - QPACK 99-Entry Static Table Verification (covers Scenario T1, U1, U3, E1)
@nogc unittest
{
    assert(QPACK_STATIC_TABLE.length == 99);
    assert(QPACK_STATIC_TABLE[0].name == ":authority");
    assert(QPACK_STATIC_TABLE[0].value == "");
    assert(QPACK_STATIC_TABLE[1].name == ":path");
    assert(QPACK_STATIC_TABLE[1].value == "/");
    assert(QPACK_STATIC_TABLE[15].name == ":method");
    assert(QPACK_STATIC_TABLE[15].value == "CONNECT");
    assert(QPACK_STATIC_TABLE[17].name == ":method");
    assert(QPACK_STATIC_TABLE[17].value == "GET");
    assert(QPACK_STATIC_TABLE[20].name == ":method");
    assert(QPACK_STATIC_TABLE[20].value == "POST");
    assert(QPACK_STATIC_TABLE[23].name == ":scheme");
    assert(QPACK_STATIC_TABLE[23].value == "https");
    assert(QPACK_STATIC_TABLE[25].name == ":status");
    assert(QPACK_STATIC_TABLE[25].value == "200");
    // RFC 9204 Appendix A Table 4 exact spacing verifications (D1)
    assert(QPACK_STATIC_TABLE[52].name == "content-type");
    assert(QPACK_STATIC_TABLE[52].value == "text/html; charset=utf-8");
    assert(QPACK_STATIC_TABLE[57].name == "strict-transport-security");
    assert(QPACK_STATIC_TABLE[57].value == "max-age=31536000; includesubdomains");
    assert(QPACK_STATIC_TABLE[58].name == "strict-transport-security");
    assert(QPACK_STATIC_TABLE[58].value == "max-age=31536000; includesubdomains; preload");
    assert(QPACK_STATIC_TABLE[85].name == "content-security-policy");
    assert(QPACK_STATIC_TABLE[85].value == "script-src 'none'; object-src 'none'; base-uri 'none'");
    assert(QPACK_STATIC_TABLE[98].name == "x-frame-options");
    assert(QPACK_STATIC_TABLE[98].value == "sameorigin");

    assert(findStaticExact(":method", "GET") == 17);
    assert(findStaticExact(":status", "200") == 25);
    assert(findStaticExact(":method", "PATCH") == -1);

    assert(findStaticName(":method") == 15);
    assert(findStaticName("content-type") == 44);
    assert(findStaticName("unknown-header") == -1);
}

/// Example:
// Spec: RFC 7541 Appendix B, Appendix C.4, RFC 9204 Section 4.1.2 - Huffman Codec, RFC Test Vectors & Security Padding (covers Scenario T1, U1, U3, E1, W2, F4)
@nogc unittest
{
    // RFC 7541 C.4.1: 'www.example.com' -> f1e3c2e5f23a6ba0ab90f4ff
    const char[] s1 = "www.example.com";
    ubyte[32] buf;
    size_t offset = 0;
    assert(encodeHuffman(s1, buf[], offset));
    assert(offset == 12);
    const ubyte[12] expected1 = [
        0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff
    ];
    assert(buf[0 .. 12] == expected1[]);

    char[32] decBuf;
    size_t decLen = 0;
    assert(decodeHuffman(expected1[], decBuf[], decLen) == H3ErrorCode.noError);
    assert(decBuf[0 .. decLen] == s1);

    // RFC 7541 C.4.2: 'no-cache' -> a8eb10649cbf
    const char[] s2 = "no-cache";
    offset = 0;
    assert(encodeHuffman(s2, buf[], offset));
    assert(offset == 6);
    const ubyte[6] expected2 = [0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf];
    assert(buf[0 .. 6] == expected2[]);

    decLen = 0;
    assert(decodeHuffman(expected2[], decBuf[], decLen) == H3ErrorCode.noError);
    assert(decBuf[0 .. decLen] == s2);

    // Security F4: Invalid padding bit (bit 0 instead of 1 in padding)
    ubyte[12] badPad = expected1;
    badPad[11] &= 0xFE; // Clear last bit
    assert(decodeHuffman(badPad[], decBuf[], decLen) == H3ErrorCode.qpackDecompressionFailed);

    // Security F4: Padding strictly longer than 7 bits (RFC 7541 Section 5.2)
    ubyte[13] excessPad;
    excessPad[0 .. 12] = expected1[];
    excessPad[12] = 0xFF; // Extra 8 bits of padding
    assert(decodeHuffman(excessPad[], decBuf[], decLen) == H3ErrorCode.qpackDecompressionFailed);

    // Security F4: Encoded string containing EOS symbol (code 0x3fffffff, 30 bits)
    ubyte[4] eosData = [0xFF, 0xFF, 0xFF, 0xFC];
    assert(decodeHuffman(eosData[], decBuf[], decLen) == H3ErrorCode.qpackDecompressionFailed);
}

/// Example:
// Spec: RFC 9204 Section 4.5, Section 4.5.2, Section 4.5.4, Section 4.5.6 - QPACK Field Section Encoding & Decoding Round-Trip (covers Scenario T1, U1, U3, E1)
@nogc unittest
{
    // Test all 99 static entries round-trip in two batches conforming to MAX_H3_HEADERS = 64
    H3HeaderField[50] part1;
    foreach (i; 0 .. 50)
        part1[i] = H3HeaderField(QPACK_STATIC_TABLE[i].name, QPACK_STATIC_TABLE[i].value);

    ubyte[4096] encBuf;
    size_t encLen = encodeQpackFieldSection(part1[], encBuf[], true);
    assert(encLen > 0);

    H3HeaderField[64] decHeaders;
    size_t decCount = 0;
    char[4096] strBuf;
    size_t strBufUsed = 0;

    assert(decodeQpackFieldSection(encBuf[0 .. encLen], decHeaders[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.noError);
    assert(decCount == 50);
    foreach (i; 0 .. 50)
    {
        assert(decHeaders[i].name == part1[i].name);
        assert(decHeaders[i].value == part1[i].value);
    }

    H3HeaderField[49] part2;
    foreach (i; 0 .. 49)
        part2[i] = H3HeaderField(QPACK_STATIC_TABLE[50 + i].name, QPACK_STATIC_TABLE[50 + i].value);

    encLen = encodeQpackFieldSection(part2[], encBuf[], true);
    assert(encLen > 0);
    decCount = 0;
    strBufUsed = 0;
    assert(decodeQpackFieldSection(encBuf[0 .. encLen], decHeaders[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.noError);
    assert(decCount == 49);
    foreach (i; 0 .. 49)
    {
        assert(decHeaders[i].name == part2[i].name);
        assert(decHeaders[i].value == part2[i].value);
    }

    // Dynamic request headers: mix of exact, name-only, and custom literal headers
    H3HeaderField[4] reqHeaders = [
        H3HeaderField(":method", "GET"), H3HeaderField(":scheme", "https"),
        H3HeaderField(":path", "/api/v1/users?id=123"),
        H3HeaderField("x-custom-slate-header", "high-assurance-value")
    ];

    // Encode with Huffman
    const size_t reqEncLen = encodeQpackFieldSection(reqHeaders[], encBuf[], true);
    assert(reqEncLen > 0);

    H3HeaderField[16] decReq;
    decCount = 0;
    strBufUsed = 0;
    assert(decodeQpackFieldSection(encBuf[0 .. reqEncLen], decReq[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.noError);
    assert(decCount == 4);
    assert(decReq[0].name == ":method" && decReq[0].value == "GET");
    assert(decReq[1].name == ":scheme" && decReq[1].value == "https");
    assert(decReq[2].name == ":path" && decReq[2].value == "/api/v1/users?id=123");
    assert(decReq[3].name == "x-custom-slate-header" && decReq[3].value == "high-assurance-value");

    // Encode without Huffman (literal raw strings)
    const size_t rawEncLen = encodeQpackFieldSection(reqHeaders[], encBuf[], false);
    assert(rawEncLen > 0);
    decCount = 0;
    strBufUsed = 0;
    assert(decodeQpackFieldSection(encBuf[0 .. rawEncLen], decReq[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.noError);
    assert(decCount == 4);
    assert(decReq[2].value == "/api/v1/users?id=123");
    assert(decReq[3].value == "high-assurance-value");
}

/// Example:
// Spec: RFC 9204 Section 4.5, RFC 9114 Section 7.2.4.1 - QPACK Decompression Bomb & Malformed Stream Rejection (covers Scenario T1, W2, F4, F6)
@nogc unittest
{
    H3HeaderField[16] decHeaders;
    size_t decCount = 0;
    char[2048] strBuf;
    size_t strBufUsed = 0;

    // 1. Truncated field section (< 2 bytes)
    ubyte[1] trunc = [0x00];
    assert(decodeQpackFieldSection(trunc[], decHeaders[], decCount, strBuf[],
            strBufUsed) == H3ErrorCode.qpackDecompressionFailed);

    // 2. Non-zero Required Insert Count when dynamic table capacity is 0
    ubyte[3] nonzeroInsert = [0x01, 0x00, 0xC0];
    assert(decodeQpackFieldSection(nonzeroInsert[], decHeaders[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.qpackDecompressionFailed);

    // 3. Out-of-bounds static index 99 (table has 99 entries 0..98)
    ubyte[32] outOfBoundsStatic;
    size_t off = 0;
    outOfBoundsStatic[off++] = 0x00; // ReqInsertCount = 0
    outOfBoundsStatic[off++] = 0x00; // DeltaBase = 0
    assert(encodePrefixedInt(99, 6, 0xC0, outOfBoundsStatic[], off));
    assert(decodeQpackFieldSection(outOfBoundsStatic[0 .. off], decHeaders[],
            decCount, strBuf[], strBufUsed) == H3ErrorCode.qpackDecompressionFailed);

    // 4. Dynamic table index when capacity is 0 (T=0, bit 6 is 0)
    ubyte[3] dynIndex = [0x00, 0x00, 0x80]; // 1 0 000000 -> T=0, Index 0
    assert(decodeQpackFieldSection(dynIndex[], decHeaders[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.qpackDecompressionFailed);

    // 5. Post-base dynamic index (0x10)
    ubyte[3] postBase = [0x00, 0x00, 0x10];
    assert(decodeQpackFieldSection(postBase[], decHeaders[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.qpackDecompressionFailed);

    // 6. Section size exceeding maxFieldSectionSize limit (RFC 9114 Section 7.2.4.1, F6)
    H3HeaderField[2] headers = [
        H3HeaderField(":method", "GET"),
        H3HeaderField(":path",
                "/very-long-path-exceeding-the-strict-limit-configured-on-this-connection")
    ];
    ubyte[256] encBuf;
    const size_t encLen = encodeQpackFieldSection(headers[], encBuf[], true);
    assert(encLen > 0);

    // Pass maxFieldSectionSize = 50 (headers size is ~110 > 50)
    assert(decodeQpackFieldSection(encBuf[0 .. encLen], decHeaders[], decCount,
            strBuf[], strBufUsed, 50) == H3ErrorCode.qpackDecompressionFailed);

    // Pass maxFieldSectionSize = 0 (0 bytes allowed, fails unconditionally per RFC 9114 / MEDIUM-8)
    assert(decodeQpackFieldSection(encBuf[0 .. encLen], decHeaders[], decCount,
            strBuf[], strBufUsed, 0) == H3ErrorCode.qpackDecompressionFailed);

    // With larger limit 500, it passes
    assert(decodeQpackFieldSection(encBuf[0 .. encLen], decHeaders[], decCount,
            strBuf[], strBufUsed, 500) == H3ErrorCode.noError);

    // 7. Negative base rejection (RFC 9204 Section 4.5.1.2, D2):
    // Required Insert Count = 0, Sign bit = 1 (0x80)
    ubyte[3] negativeBase = [0x00, 0x80, 0xD1]; // 0x80 has sign bit = 1
    assert(decodeQpackFieldSection(negativeBase[], decHeaders[], decCount,
            strBuf[], strBufUsed) == H3ErrorCode.qpackDecompressionFailed);
}
