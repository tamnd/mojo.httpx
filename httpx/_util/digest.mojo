"""MD5, SHA-1, SHA-256 and SHA-512, for digest authentication.

Written out here rather than taken from somewhere because there is nowhere to
take them from. Mojo 1.0 ships no hash functions of this kind, and the OpenSSL
this library already loads is optional: it is needed for `https://` and nothing
else, and a digest authenticated request over plain `http://` should not start
by looking for a TLS library. So the four algorithms RFC 7616 names are here,
in about as much code as the binding would have been.

None of these are worth anything as password hashes and MD5 and SHA-1 are not
worth anything as signatures either. They are here because a server that asks
for digest auth chooses the algorithm and most of them still choose MD5, and a
client that refused would simply not be able to talk to those servers. Nothing
else in this library uses them.

The implementations are one shot rather than incremental. A digest auth
challenge hashes a few hundred bytes at most, so there is no body to stream and
no state to keep between calls.
"""

from std.bit import rotate_bits_left

comptime _MD5_K: InlineArray[UInt32, 64] = [
    0xD76AA478,
    0xE8C7B756,
    0x242070DB,
    0xC1BDCEEE,
    0xF57C0FAF,
    0x4787C62A,
    0xA8304613,
    0xFD469501,
    0x698098D8,
    0x8B44F7AF,
    0xFFFF5BB1,
    0x895CD7BE,
    0x6B901122,
    0xFD987193,
    0xA679438E,
    0x49B40821,
    0xF61E2562,
    0xC040B340,
    0x265E5A51,
    0xE9B6C7AA,
    0xD62F105D,
    0x02441453,
    0xD8A1E681,
    0xE7D3FBC8,
    0x21E1CDE6,
    0xC33707D6,
    0xF4D50D87,
    0x455A14ED,
    0xA9E3E905,
    0xFCEFA3F8,
    0x676F02D9,
    0x8D2A4C8A,
    0xFFFA3942,
    0x8771F681,
    0x6D9D6122,
    0xFDE5380C,
    0xA4BEEA44,
    0x4BDECFA9,
    0xF6BB4B60,
    0xBEBFBC70,
    0x289B7EC6,
    0xEAA127FA,
    0xD4EF3085,
    0x04881D05,
    0xD9D4D039,
    0xE6DB99E5,
    0x1FA27CF8,
    0xC4AC5665,
    0xF4292244,
    0x432AFF97,
    0xAB9423A7,
    0xFC93A039,
    0x655B59C3,
    0x8F0CCC92,
    0xFFEFF47D,
    0x85845DD1,
    0x6FA87E4F,
    0xFE2CE6E0,
    0xA3014314,
    0x4E0811A1,
    0xF7537E82,
    0xBD3AF235,
    0x2AD7D2BB,
    0xEB86D391,
]

comptime _MD5_SHIFT: InlineArray[UInt32, 64] = [
    0x07,
    0x0C,
    0x11,
    0x16,
    0x07,
    0x0C,
    0x11,
    0x16,
    0x07,
    0x0C,
    0x11,
    0x16,
    0x07,
    0x0C,
    0x11,
    0x16,
    0x05,
    0x09,
    0x0E,
    0x14,
    0x05,
    0x09,
    0x0E,
    0x14,
    0x05,
    0x09,
    0x0E,
    0x14,
    0x05,
    0x09,
    0x0E,
    0x14,
    0x04,
    0x0B,
    0x10,
    0x17,
    0x04,
    0x0B,
    0x10,
    0x17,
    0x04,
    0x0B,
    0x10,
    0x17,
    0x04,
    0x0B,
    0x10,
    0x17,
    0x06,
    0x0A,
    0x0F,
    0x15,
    0x06,
    0x0A,
    0x0F,
    0x15,
    0x06,
    0x0A,
    0x0F,
    0x15,
    0x06,
    0x0A,
    0x0F,
    0x15,
]

comptime _SHA256_K: InlineArray[UInt32, 64] = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
]

comptime _SHA512_K: InlineArray[UInt64, 80] = [
    0x428A2F98D728AE22,
    0x7137449123EF65CD,
    0xB5C0FBCFEC4D3B2F,
    0xE9B5DBA58189DBBC,
    0x3956C25BF348B538,
    0x59F111F1B605D019,
    0x923F82A4AF194F9B,
    0xAB1C5ED5DA6D8118,
    0xD807AA98A3030242,
    0x12835B0145706FBE,
    0x243185BE4EE4B28C,
    0x550C7DC3D5FFB4E2,
    0x72BE5D74F27B896F,
    0x80DEB1FE3B1696B1,
    0x9BDC06A725C71235,
    0xC19BF174CF692694,
    0xE49B69C19EF14AD2,
    0xEFBE4786384F25E3,
    0x0FC19DC68B8CD5B5,
    0x240CA1CC77AC9C65,
    0x2DE92C6F592B0275,
    0x4A7484AA6EA6E483,
    0x5CB0A9DCBD41FBD4,
    0x76F988DA831153B5,
    0x983E5152EE66DFAB,
    0xA831C66D2DB43210,
    0xB00327C898FB213F,
    0xBF597FC7BEEF0EE4,
    0xC6E00BF33DA88FC2,
    0xD5A79147930AA725,
    0x06CA6351E003826F,
    0x142929670A0E6E70,
    0x27B70A8546D22FFC,
    0x2E1B21385C26C926,
    0x4D2C6DFC5AC42AED,
    0x53380D139D95B3DF,
    0x650A73548BAF63DE,
    0x766A0ABB3C77B2A8,
    0x81C2C92E47EDAEE6,
    0x92722C851482353B,
    0xA2BFE8A14CF10364,
    0xA81A664BBC423001,
    0xC24B8B70D0F89791,
    0xC76C51A30654BE30,
    0xD192E819D6EF5218,
    0xD69906245565A910,
    0xF40E35855771202A,
    0x106AA07032BBD1B8,
    0x19A4C116B8D2D0C8,
    0x1E376C085141AB53,
    0x2748774CDF8EEB99,
    0x34B0BCB5E19B48A8,
    0x391C0CB3C5C95A63,
    0x4ED8AA4AE3418ACB,
    0x5B9CCA4F7763E373,
    0x682E6FF3D6B2B8A3,
    0x748F82EE5DEFB2FC,
    0x78A5636F43172F60,
    0x84C87814A1F0AB72,
    0x8CC702081A6439EC,
    0x90BEFFFA23631E28,
    0xA4506CEBDE82BDE9,
    0xBEF9A3F7B2C67915,
    0xC67178F2E372532B,
    0xCA273ECEEA26619C,
    0xD186B8C721C0C207,
    0xEADA7DD6CDE0EB1E,
    0xF57D4F7FEE6ED178,
    0x06F067AA72176FBA,
    0x0A637DC5A2C898A6,
    0x113F9804BEF90DAE,
    0x1B710B35131C471B,
    0x28DB77F523047D84,
    0x32CAAB7B40C72493,
    0x3C9EBE0A15C9BEBC,
    0x431D67C49C100D4C,
    0x4CC5D4BECB3E42B6,
    0x597F299CFC657E2A,
    0x5FCB6FAB3AD6FAEC,
    0x6C44198C4A475817,
]

comptime _SHA256_INIT: InlineArray[UInt32, 8] = [
    0x6A09E667,
    0xBB67AE85,
    0x3C6EF372,
    0xA54FF53A,
    0x510E527F,
    0x9B05688C,
    0x1F83D9AB,
    0x5BE0CD19,
]

comptime _SHA512_INIT: InlineArray[UInt64, 8] = [
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179,
]


struct Algorithm(Equatable, ImplicitlyCopyable, Movable):
    """Which of the four to use.

    A value rather than a function pointer, because the caller picks it from a
    string a server sent and a bad string has to be rejected rather than
    called.
    """

    var value: UInt8

    def __init__(out self, value: UInt8):
        self.value = value

    comptime MD5 = Algorithm(0)
    comptime SHA1 = Algorithm(1)
    comptime SHA256 = Algorithm(2)
    comptime SHA512 = Algorithm(3)


def _rotl32(x: UInt32, n: UInt32) -> UInt32:
    return (x << n) | (x >> (32 - n))


def _rotr32(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))


def _rotr64(x: UInt64, n: UInt64) -> UInt64:
    return (x >> n) | (x << (64 - n))


def _padded[
    o: ImmOrigin
](data: Span[UInt8, o], block: Int, little_endian: Bool) -> List[UInt8]:
    """The message with the terminator, the zero fill and the bit count on it.

    The same shape for all four algorithms and the reason they can share one
    function: a single set bit, zeros up to the last field, and the length of
    the message in bits. Only two things differ, the block size and which end
    the length is written from, and both are arguments.

    Padding by copying the whole message costs an allocation that a real hash
    library would avoid by padding only the final block. What is being hashed
    here is a few hundred bytes of header, so the copy is not worth the two
    extra code paths it would save.
    """
    var out = List[UInt8]()
    out.extend(data)
    out.append(0x80)

    # SHA-512 writes the length in 128 bits. The top 64 are always zero for any
    # message that fits in memory, but they still have to be there.
    var length_field = 8 if block == 64 else 16
    while (len(out) + length_field) % block != 0:
        out.append(0)

    var bits = UInt64(len(data)) * 8
    if little_endian:
        for i in range(8):
            out.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))
    else:
        for _ in range(length_field - 8):
            out.append(0)
        for i in range(8):
            out.append(UInt8((bits >> UInt64(8 * (7 - i))) & 0xFF))
    return out^


def _read_be32[o: ImmOrigin](data: Span[UInt8, o], at: Int) -> UInt32:
    return (
        (UInt32(data[at]) << 24)
        | (UInt32(data[at + 1]) << 16)
        | (UInt32(data[at + 2]) << 8)
        | UInt32(data[at + 3])
    )


def _read_be64[o: ImmOrigin](data: Span[UInt8, o], at: Int) -> UInt64:
    var out = UInt64(0)
    for i in range(8):
        out = (out << 8) | UInt64(data[at + i])
    return out


def _write_be32(mut out: List[UInt8], value: UInt32):
    for i in range(4):
        out.append(UInt8((value >> UInt32(8 * (3 - i))) & 0xFF))


def _write_be64(mut out: List[UInt8], value: UInt64):
    for i in range(8):
        out.append(UInt8((value >> UInt64(8 * (7 - i))) & 0xFF))


def md5[o: ImmOrigin](data: Span[UInt8, o]) -> List[UInt8]:
    """RFC 1321. Sixteen bytes, and the only one of the four that is little
    endian throughout."""
    var k = materialize[_MD5_K]()
    var shift = materialize[_MD5_SHIFT]()
    var msg = _padded(data, 64, True)

    var a0 = UInt32(0x67452301)
    var b0 = UInt32(0xEFCDAB89)
    var c0 = UInt32(0x98BADCFE)
    var d0 = UInt32(0x10325476)

    for at in range(0, len(msg), 64):
        var m = InlineArray[UInt32, 16](fill=0)
        for i in range(16):
            var base = at + i * 4
            m[i] = (
                UInt32(msg[base])
                | (UInt32(msg[base + 1]) << 8)
                | (UInt32(msg[base + 2]) << 16)
                | (UInt32(msg[base + 3]) << 24)
            )

        var a = a0
        var b = b0
        var c = c0
        var d = d0
        for i in range(64):
            var f: UInt32
            var g: Int
            if i < 16:
                f = (b & c) | (~b & d)
                g = i
            elif i < 32:
                f = (d & b) | (~d & c)
                g = (5 * i + 1) % 16
            elif i < 48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            else:
                f = c ^ (b | ~d)
                g = (7 * i) % 16

            f = f + a + k[i] + m[g]
            a = d
            d = c
            c = b
            b = b + _rotl32(f, shift[i])

        a0 += a
        b0 += b
        c0 += c
        d0 += d

    var out = List[UInt8]()
    var words: InlineArray[UInt32, 4] = [a0, b0, c0, d0]
    for w in range(4):
        for i in range(4):
            out.append(UInt8((words[w] >> UInt32(8 * i)) & 0xFF))
    return out^


def sha1[o: ImmOrigin](data: Span[UInt8, o]) -> List[UInt8]:
    """RFC 3174. Twenty bytes."""
    var msg = _padded(data, 64, False)
    var h: InlineArray[UInt32, 5] = [
        0x67452301,
        0xEFCDAB89,
        0x98BADCFE,
        0x10325476,
        0xC3D2E1F0,
    ]

    for at in range(0, len(msg), 64):
        var w = InlineArray[UInt32, 80](fill=0)
        for i in range(16):
            w[i] = _read_be32(msg, at + i * 4)
        for i in range(16, 80):
            w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        for i in range(80):
            var f: UInt32
            var k: UInt32
            if i < 20:
                f = (b & c) | (~b & d)
                k = 0x5A827999
            elif i < 40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            elif i < 60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            else:
                f = b ^ c ^ d
                k = 0xCA62C1D6

            var temp = _rotl32(a, 5) + f + e + k + w[i]
            e = d
            d = c
            c = _rotl32(b, 30)
            b = a
            a = temp

        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e

    var out = List[UInt8]()
    for i in range(5):
        _write_be32(out, h[i])
    return out^


def sha256[o: ImmOrigin](data: Span[UInt8, o]) -> List[UInt8]:
    """FIPS 180-4. Thirty two bytes."""
    var k = materialize[_SHA256_K]()
    var h = materialize[_SHA256_INIT]()
    var msg = _padded(data, 64, False)

    for at in range(0, len(msg), 64):
        var w = InlineArray[UInt32, 64](fill=0)
        for i in range(16):
            w[i] = _read_be32(msg, at + i * 4)
        for i in range(16, 64):
            var s0 = (
                _rotr32(w[i - 15], 7)
                ^ _rotr32(w[i - 15], 18)
                ^ (w[i - 15] >> 3)
            )
            var s1 = (
                _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10)
            )
            w[i] = w[i - 16] + s0 + w[i - 7] + s1

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for i in range(64):
            var s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25)
            var ch = (e & f) ^ (~e & g)
            var temp1 = hh + s1 + ch + k[i] + w[i]
            var s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var temp2 = s0 + maj

            hh = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2

        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e
        h[5] += f
        h[6] += g
        h[7] += hh

    var out = List[UInt8]()
    for i in range(8):
        _write_be32(out, h[i])
    return out^


def sha512[o: ImmOrigin](data: Span[UInt8, o]) -> List[UInt8]:
    """FIPS 180-4. Sixty four bytes, and SHA-256 with wider words and more
    rounds."""
    var k = materialize[_SHA512_K]()
    var h = materialize[_SHA512_INIT]()
    var msg = _padded(data, 128, False)

    for at in range(0, len(msg), 128):
        var w = InlineArray[UInt64, 80](fill=0)
        for i in range(16):
            w[i] = _read_be64(msg, at + i * 8)
        for i in range(16, 80):
            var s0 = (
                _rotr64(w[i - 15], 1) ^ _rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
            )
            var s1 = (
                _rotr64(w[i - 2], 19) ^ _rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
            )
            w[i] = w[i - 16] + s0 + w[i - 7] + s1

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for i in range(80):
            var s1 = _rotr64(e, 14) ^ _rotr64(e, 18) ^ _rotr64(e, 41)
            var ch = (e & f) ^ (~e & g)
            var temp1 = hh + s1 + ch + k[i] + w[i]
            var s0 = _rotr64(a, 28) ^ _rotr64(a, 34) ^ _rotr64(a, 39)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var temp2 = s0 + maj

            hh = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2

        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e
        h[5] += f
        h[6] += g
        h[7] += hh

    var out = List[UInt8]()
    for i in range(8):
        _write_be64(out, h[i])
    return out^


def digest[
    o: ImmOrigin
](algorithm: Algorithm, data: Span[UInt8, o]) raises -> List[UInt8]:
    """The raw digest, chosen at run time."""
    if algorithm == Algorithm.MD5:
        return md5(data)
    if algorithm == Algorithm.SHA1:
        return sha1(data)
    if algorithm == Algorithm.SHA256:
        return sha256(data)
    if algorithm == Algorithm.SHA512:
        return sha512(data)
    raise Error("RuntimeError: unknown digest algorithm")


def hex_digest[
    o: ImmOrigin
](algorithm: Algorithm, data: Span[UInt8, o]) raises -> String:
    """The digest as lowercase hexadecimal, which is the form every digest
    auth field is written in."""
    return hex(digest(algorithm, data))


def hex[o: ImmOrigin](data: Span[UInt8, o]) -> String:
    """Lowercase hexadecimal, two characters a byte and nothing else."""
    comptime digits = StaticString("0123456789abcdef")
    var out = String()
    for i in range(len(data)):
        out += digits[byte = Int(data[i] >> 4) : Int(data[i] >> 4) + 1]
        out += digits[byte = Int(data[i] & 0xF) : Int(data[i] & 0xF) + 1]
    return out^
