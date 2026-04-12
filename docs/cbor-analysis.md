# CBOR Data Format: Detailed Analysis

## Table of Contents

1. [Specification](#1-specification)
2. [Existing Implementations](#2-existing-implementations)
3. [Test Vectors and Implementation Validation](#3-test-vectors-and-implementation-validation)
4. [Performance Approaches of Reference Libraries](#4-performance-approaches-of-reference-libraries)

---

## 1. Specification

### 1.1 History and Evolution

CBOR (Concise Binary Object Representation) was originally published as **RFC 7049** in October 2013, authored by Carsten Bormann (Universität Bremen TZI) and Paul Hoffman (VPN Consortium). It was designed for constrained environments (IoT, embedded systems) while maintaining a JSON-compatible data model.

In December 2020, **RFC 8949** was published as an Internet Standard, obsoleting RFC 7049. RFC 8949 maintains full wire-level compatibility — it is not a new version of the format. Key changes:

- **Editorial improvements**: More thorough explanations of encoding rules and edge cases
- **Errata fixes**: Incorporated all known errata from RFC 7049
- **Deterministic encoding**: "Canonical CBOR" replaced with "Core Deterministic Encoding Requirements," using a simpler map key sorting order
- **Terminology shift**: "Canonical" deliberately avoided in favor of "deterministic"
- **Clarified handling** of duplicate map keys, UTF-8 validation, and numeric reduction rules

### 1.2 Core Data Model: Major Types (0–7)

Every CBOR data item begins with an initial byte. The high 3 bits encode the **major type** (0–7), and the low 5 bits encode **additional information**.

| Major Type | Meaning | Content |
|------------|---------|---------|
| **0** | Unsigned integer | 0 to 2^64 − 1 |
| **1** | Negative integer | −1 to −2^64 (encoded as −1 − n) |
| **2** | Byte string | N raw bytes |
| **3** | Text string | N bytes of UTF-8 |
| **4** | Array | N heterogeneous data items |
| **5** | Map | 2N alternating key-value data items |
| **6** | Semantic tag | Tag number + 1 enclosed data item |
| **7** | Simple values / floats | false, true, null, undefined, float16/32/64 |

### 1.3 Additional Information Encoding

The low 5 bits of the initial byte (values 0–31):

| Value | Meaning |
|-------|---------|
| 0–23 | Value/length is the additional info itself (no extra bytes) |
| 24 | Next 1 byte is a uint8 argument |
| 25 | Next 2 bytes are a uint16 (network byte order / big-endian) |
| 26 | Next 4 bytes are a uint32 (network byte order) |
| 27 | Next 8 bytes are a uint64 (network byte order) |
| 28–30 | Reserved; not well-formed in current CBOR |
| 31 | Indefinite length (major types 2–5); break code (major type 7) |

### 1.4 Encoding Rules by Data Type

**Integers (Major Types 0, 1):**
- Unsigned: major type 0 + argument = value. E.g., `0x0a` = 10, `0x1864` = 100
- Negative: major type 1 + argument = (−1 − value). E.g., `0x20` = −1, `0x3863` = −100

**Byte Strings (Major Type 2) and Text Strings (Major Type 3):**
- Length-prefixed: initial byte encodes length, followed by raw bytes
- Text strings must be valid UTF-8

**Arrays (Major Type 4) and Maps (Major Type 5):**
- Length-prefixed: argument = number of items (arrays) or pairs (maps)
- Maps alternate key, value, key, value…
- Keys can be any CBOR data type (not limited to strings like JSON)

**Tags (Major Type 6):**
- Argument = tag number, followed by exactly one enclosed data item
- Adds semantic meaning (e.g., tag 0 = date/time string, tag 1 = epoch timestamp)

**Simple Values and Floats (Major Type 7):**
- Additional info 20 = `false`, 21 = `true`, 22 = `null`, 23 = `undefined`
- Additional info 25 = IEEE 754 half-precision float (16-bit)
- Additional info 26 = IEEE 754 single-precision float (32-bit)
- Additional info 27 = IEEE 754 double-precision float (64-bit)

### 1.5 Indefinite-Length Encoding

Major types 2–5 support indefinite-length encoding (additional info = 31):

- **Byte/Text strings**: A sequence of definite-length chunks of the same major type, terminated by the break code `0xFF`. Text string chunks must not split Unicode code points.
- **Arrays/Maps**: Items appear sequentially, terminated by `0xFF`.
- Example: `0x9F 01 82 02 03 FF` decodes as `[1, [2, 3]]`

### 1.6 Deterministic Encoding

RFC 8949 Section 4 defines two levels:

**Preferred Serialization (Section 4.1):**
- Always use the shortest argument form for integers and lengths
- Use definite-length encoding whenever the length is known at serialization start
- Use the shortest floating-point encoding that preserves the value (e.g., 1.5 as `0xf93e00` in float16)

**Core Deterministic Encoding Requirements (Section 4.2.1):**
- Preferred serialization MUST be used
- Indefinite-length items MUST NOT be used
- Map keys MUST be sorted in bytewise lexicographic order of their deterministic encodings (shorter keys sort first; same-length keys sort by byte values)
- Floating-point values MUST use the shortest form preserving the value

> **Note:** The Core Deterministic sorting order differs from RFC 7049's "Canonical CBOR," which used a more complex three-step ordering approach. RFC 8949's approach is simpler and aligns with length-first lexicographic comparison.

**Beyond the RFC:**
- **Gordian dCBOR** (draft-mcnally-deterministic-cbor): A stricter application profile for cryptographic applications
- **draft-bormann-cbor-det**: Further IETF work on deterministic encoding guidance

### 1.7 Tag System and IANA Registry

Tags (major type 6) are registered in the [IANA CBOR Tags Registry](https://www.iana.org/assignments/cbor-tags/cbor-tags.xhtml).

Key registered tags:

| Tag | Data Item | Semantics |
|-----|-----------|-----------|
| 0 | text string | Standard date/time string (RFC 3339) |
| 1 | integer/float | Epoch-based date/time |
| 2 | byte string | Unsigned bignum |
| 3 | byte string | Negative bignum |
| 4 | array | Decimal fraction [exponent, mantissa] |
| 5 | array | Bigfloat [exponent, mantissa] |
| 16 | COSE_Encrypt0 | COSE Single Recipient Encrypted Data |
| 17 | COSE_Mac0 | COSE MAC without Recipients |
| 18 | COSE_Sign1 | COSE Single Signer Data |
| 21–23 | any | Expected base64url / base64 / base16 conversion |
| 24 | byte string | Encoded CBOR data item |
| 32 | text string | URI |
| 37 | byte string | Binary UUID |
| 55799 | any | Self-described CBOR (magic marker, no semantic change) |

### 1.8 Comparison with Other Formats

| Feature | CBOR | JSON | MessagePack | BSON | Protocol Buffers |
|---------|------|------|-------------|------|------------------|
| Format | Binary | Text | Binary | Binary | Binary |
| Schema | Optional | None | Optional | Optional | **Required** |
| Self-describing | Yes | Yes | Yes | Yes | **No** |
| Standardization | IETF RFC 8949 | IETF RFC 8259 | Community spec | De facto (MongoDB) | De facto (Google) |
| Binary data | Native byte strings | Base64 workaround | Native | Native | Native |
| Extensibility | IANA tag registry | None | `ext` type | DB-centric types | Proto extensions |
| Indefinite length | Yes | N/A | **No** | N/A | N/A |
| Deterministic encoding | Defined in spec | N/A | Not specified | Not specified | Non-trivial |
| Compact for small data | Excellent | Poor | Good | Poor | Excellent |
| IoT/Constrained | Designed for it | Too verbose | Possible | Too heavy | Needs codegen |
| Human readable | No (diagnostic notation exists) | Yes | No | No | No (.proto is) |

Key differentiators:
- ~27% smaller than JSON with similar performance
- IETF standard with formal IANA tag registry (vs. MessagePack's informal `ext` type)
- Indefinite-length streaming (MessagePack requires upfront element counts)
- Native in WebAuthn/FIDO2, CoAP, COSE security protocols
- Deterministic encoding defined in spec (critical for cryptographic use cases)

### 1.9 Related Specifications

| Spec | RFC | Description |
|------|-----|-------------|
| **COSE** | RFC 9052 + 9053 | CBOR Object Signing and Encryption. Signatures, MACs, encryption using CBOR. |
| **CWT** | RFC 8392 | CBOR Web Token. CBOR equivalent of JWT, built on COSE. |
| **CDDL** | RFC 8610 + 9682 + 9165 | Concise Data Definition Language. Machine-readable schema for CBOR/JSON. |
| **CBOR Sequences** | RFC 8742 | Concatenated CBOR items (not wrapped in an array). Useful for streaming/logs. |
| **Typed Arrays** | RFC 8746 | Tags for efficient homogeneous arrays. |
| **Date Tags** | RFC 8943 | Date without time-of-day. |
| **IP Address Tags** | RFC 9164 | IPv4/IPv6 addresses and prefixes. |
| **OID Tags** | RFC 9090 | Object Identifiers. |
| **Time/Duration** | RFC 9581 | Time, duration, and period tags. |
| **CBOR-LD** | W3C Draft | CBOR serialization for Linked Data (JSON-LD). 60%+ compression via context dictionaries. |

---

## 2. Existing Implementations

### 2.1 Rust

| Library | Approach | `no_std` | Serde | Notes |
|---------|----------|----------|-------|-------|
| **ciborium** | Serde-based | No | Yes | Recommended serde_cbor replacement. Smallest lossless encoding. Preserves map order via `Vec<(Value, Value)>`. Packed encoding support. |
| **minicbor** | Custom Encode/Decode traits | **Yes** | Via minicbor-serde | Zero-copy decoding via borrowed slices. `CborLen` trait for pre-allocation. Tokenizer. Derive macros. 150+ releases. |
| **cbor4ii** | Custom traits | Yes | No | Fast alternative with `no_std` support. |
| **sk-cbor** | Value-based | **Yes** (serialization) | No | From Google's OpenSK/FIDO2. Canonical key ordering. Lightweight, embedded-focused. |
| **serde_cbor** | Serde-based | Partial | Yes | **Archived/unmaintained**. Author recommends ciborium or minicbor. |

**Recommendations:** ciborium for serde-based workflows; minicbor for `no_std`/embedded or fine-grained control; sk-cbor for minimal FIDO2 use cases.

### 2.2 C / C++

| Library | Code Size | Features | Notes |
|---------|-----------|----------|-------|
| **QCBOR** | 1KB–15.5KB configurable | Full RFC 8949, zero-copy, Spiffy Decode, no malloc, 176B encode / 312B decode context | Commercial-quality. No recursion. Passes static analyzers. |
| **TinyCBOR** | Very small | No-alloc encoder/decoder | Intel. Minimalist API. IoTivity origin. |
| **libcbor** | Medium | Streaming/incremental, full spec | Most complete C implementation. |
| **cn-cbor** | ~880B ARM | Basic encode/decode | Extremely minimal. Most constrained devices. |
| **cb0r** | Tiny | Read-only microcontroller decoder | Zero-memory-footprint design. |
| **Qt (5.12+)** | N/A | QCborValue built-in | Integrated into Qt framework. |

**Recommendations:** QCBOR for security-critical/embedded; TinyCBOR for minimal footprint; libcbor for general C99 with streaming.

### 2.3 Go

| Library | Features | Notes |
|---------|----------|-------|
| **fxamacker/cbor** (v2.9) | RFC 8949 + 8742, Core Deterministic, CTAP2 Canonical, Preferred Serialization, struct tags, float shrinking, duplicate key detection, fuzz tested | **Dominant Go implementation**. encoding/json-compatible API. NCC Group audited. |
| **ugorji/go/codec** | Multi-format (JSON, CBOR, MsgPack) | Significantly slower for CBOR-specific workloads. |

### 2.4 Python

| Library | Features | Notes |
|---------|----------|-------|
| **cbor2** (v5.6) | Pure Python + optional C backend, extensive tags, canonical encoding, cyclic references, streaming | **The recommended Python CBOR library**. JSON/pickle-like API. |

### 2.5 JavaScript / TypeScript

| Library | Features | Notes |
|---------|----------|-------|
| **cbor-x** | RFC 8949/8746/8742, Packed CBOR, record extension, optional native addon, ~1.5GB/s encode / ~2GB/s decode | **Fastest JS CBOR**. 3–10x faster than alternatives, often faster than JSON.parse. |
| **cborg** | Strict decoding, configurable float/map sorting | Focus on strictness and correctness. |
| **node-cbor** | Server-side Node.js | Mature, widely used. |

### 2.6 Java / Kotlin / .NET

| Library | Language | Notes |
|---------|----------|-------|
| **jackson-dataformats-binary** | Java | CBOR in the Jackson ecosystem. Most popular. |
| **kotlinx.serialization** | Kotlin | Built-in CBOR support. First-class language integration. |
| **System.Formats.Cbor** | .NET | Official Microsoft BCL implementation. |
| **Dahomey.Cbor** | .NET | High-performance third-party. |

### 2.7 Other Languages

- **Haskell**: cborg (high-speed, with tools)
- **Scala**: borer (idiomatic, type-class based)
- **OCaml**: cbor (minimal), orsetto (streaming codecs)
- **Swift**: SwiftCBOR, CBORCoding (Codable protocol)
- **Erlang/Elixir**: erl-cbor (extensible tags, depth limits)
- **Ruby**: cbor-ruby (MessagePack-derived)
- **Perl**: CBOR::XS (high-performance), CBOR::Free, CBOR::PP
- **Dart**: cbor (full RFC 7049)
- **Lua**: lua-cbor, spc476/CBOR (most comprehensive)

---

## 3. Test Vectors and Implementation Validation

### 3.1 RFC 8949 Appendix A Test Vectors

The RFC includes comprehensive test vectors. Selected examples:

| Hex | Decoded Value | Type |
|-----|---------------|------|
| `00` | 0 | unsigned int |
| `01` | 1 | unsigned int |
| `0a` | 10 | unsigned int |
| `17` | 23 | unsigned int |
| `1818` | 24 | unsigned int (1-byte argument) |
| `1864` | 100 | unsigned int |
| `1903e8` | 1000 | unsigned int |
| `20` | −1 | negative int |
| `3863` | −100 | negative int |
| `f4` | false | simple value |
| `f5` | true | simple value |
| `f6` | null | simple value |
| `f7` | undefined | simple value |
| `f93c00` | 1.0 | float16 |
| `f93e00` | 1.5 | float16 |
| `fa47c35000` | 100000.0 | float32 |
| `fb3ff199999999999a` | 1.1 | float64 |
| `40` | h'' (empty byte string) | byte string |
| `4401020304` | h'01020304' | byte string |
| `60` | "" | text string |
| `6161` | "a" | text string |
| `80` | [] | array |
| `83010203` | [1, 2, 3] | array |
| `a0` | {} | map |
| `a201020304` | {1: 2, 3: 4} | map |

### 3.2 Community Test Resources

**Test vectors repository:** [github.com/cbor/test-vectors](https://github.com/cbor/test-vectors)
- `appendix_a.json` with all RFC 8949 Appendix A examples
- Each vector includes: `cbor` (base64), `hex`, `roundtrip` (boolean), `decoded` (JSON), `diagnostic` (CBOR diagnostic notation)

**cbor.me:** Web-based CBOR playground ([cbor.me](https://cbor.me/))
- Convert between binary CBOR (hex) and diagnostic notation
- Validate CBOR data interactively
- Test round-trip encoding/decoding

**cbor-diag:** CLI tools for CBOR conversion (`gem install cbor-diag`), [github.com/cabo/cbor-diag](https://github.com/cabo/cbor-diag)

**CDDL tool:** Schema validation for CBOR (`gem install cddl`). Rust implementation at [github.com/anweiss/cddl](https://github.com/anweiss/cddl).

### 3.3 How Implementations Validate Conformance

| Technique | Description | Used by |
|-----------|-------------|---------|
| **Round-trip testing** | Encode → decode → re-encode, verify identical bytes | Most implementations |
| **Appendix A vectors** | Test against RFC's reference encodings | Most implementations |
| **Fuzz testing** | Random/adversarial input to find crashes and edge cases | fxamacker/cbor, cbor2, many Rust libs |
| **CDDL validation** | Schema-based structural validation | Specification authors, protocol implementors |
| **Security audits** | Third-party code review | fxamacker/cbor (NCC Group) |
| **Formal verification** | EverCBOR (Microsoft Research) — separation logic for verified parsing | Research/academic |

---

## 4. Performance Approaches of Reference Libraries

### 4.1 General High-Performance Techniques

| Technique | Description |
|-----------|-------------|
| Zero-copy parsing | Return references/slices into input buffer rather than copying |
| Streaming/pull-based parsing | Process data incrementally without full tree materialization |
| No heap allocation | Use stack or caller-provided buffers exclusively |
| Deferred error checking | Track errors internally, check once at the end |
| Structure-aware encoding | Reuse known object shapes across messages |
| Float size reduction | Automatically downsize float64 → float32 → float16 |
| Native addons/C extensions | Offload hot paths to compiled code |
| Compile-time code generation | Derive macros / codegen for type-specific encode/decode |

### 4.2 QCBOR (C) — Constrained Device Champion

- **Zero malloc:** Fixed-size contexts (encode: 176B, decode: 312B, item: 56B). Complete memory control.
- **No recursion:** Predictable, bounded stack consumption for embedded systems.
- **Dead code elimination:** Configurable via `QCBOR_DISABLE_XXX` defines. Code ranges from ~1KB (minimal) to ~15.5KB (full features).
- **Deferred error checking:** Internal error state tracking. Callers check status only at the end, reducing branch overhead.
- **Zero-copy byte strings:** Decoded strings return pointers into the input buffer.
- **UsefulBuf abstraction:** Safe binary data handling that passes static analyzers without per-operation bounds-check overhead.
- **Spiffy Decode:** Higher-level API for direct map item retrieval by label with automatic duplicate detection — combines DOM convenience with streaming memory efficiency.
- **Portable C99:** Only depends on `<stdint.h>`, `<stddef.h>`, `<stdbool.h>`, `<string.h>`. Optional `<math.h>` / `<fenv.h>` can be disabled.

### 4.3 cbor-x (JavaScript/C++) — Speed King of JS

- **Record structure extension (key driver):** Detects recurring object shapes and encodes the structure definition once. Subsequent instances reference structures by index.
  - 2–3x decode speedup, 15–50% size reduction
  - Up to 64 structure definitions per encoder
- **Optional native C++ addon:** Node.js native addon for hot-path acceleration, pure JS fallback for browser/Deno.
- **Buffer reuse:** `useBuffer()` reduces GC pressure.
- **String bundling:** 30–50% faster browser decoding via string concatenation.
- **`copyBuffers` option:** When disabled, returns buffer slices (views) instead of copies.

**Benchmarks** (Node 14.8, i7-4770):

| Library | Encode ops/sec | Decode ops/sec |
|---------|---------------|----------------|
| cbor-x (shared structs) | 35,665 | 75,340 |
| cbor-x (standard) | 32,287 | 18,904 |
| JSON.stringify/parse | 16,386 | 17,720 |
| @msgpack/msgpack | 20,235 | 14,228 |
| cbor (npm) | 1,537 | 605 |

Streaming: EncoderStream 1.9M ops/sec, DecoderStream 3.4M ops/sec.

### 4.4 fxamacker/cbor (Go) — Security + Speed

- **No `unsafe` package:** Speed through careful algorithm design, not pointer tricks.
- **Fast malformed data rejection:** ~47 ns/op to reject invalid input vs. competitors at milliseconds (124,000x faster than ugorji/go on one benchmark).
- **Struct tag optimization:**
  - `toarray`: Eliminates field names entirely (positional CBOR array). A 3-level nested empty struct = 1 byte CBOR vs. 18 bytes JSON.
  - `keyasint`: Field names as compact integers (1 byte for first 24 fields).
- **Float shrinking:** Automatic float64 → float32 → float16 when lossless.
- **User buffer support (v2.7+):** `MarshalToBuffer()` avoids internal buffer pool allocation.
- **Preset encoding modes:** Thread-safe, reusable `EncMode`/`DecMode` configurations for Core Deterministic, CTAP2, Canonical, and Preferred encoding.

### 4.5 minicbor (Rust) — Embedded Efficiency

- **`no_std` first:** Core works without allocator. Progressive feature flags (`alloc`, `std`, `derive`).
- **Zero-copy decoding:** `&str` and `&[u8]` borrow directly from input buffer. `Decode` trait is parameterized by input lifetime.
- **No serde overhead:** `Encode`/`Decode` traits compile to direct method calls (not visitor-pattern dispatch like serde).
- **`CborLen` trait:** Pre-calculate exact encoded size for precise buffer allocation (no realloc/grow).
- **Type-directed decoding:** Call `decoder.u32()` or `decoder.str()` rather than deserializing into a generic `Value` enum. Avoids dynamic dispatch.
- **Tokenizer:** `Iterator<Item = Token>` for streaming validation/inspection without full deserialization.
- **Derive macros:** Compile-time code generation for struct/enum encoding.

### 4.6 Rust CBOR Benchmark Comparison

From the [Rust serialization benchmark](https://github.com/djkoloski/rust_serialization_benchmark) (same dataset):

| Library | Serialize | Deserialize | Size |
|---------|-----------|-------------|------|
| cbor4ii 1.0.0 | 524 µs | 5.18 ms | 1,407,835 B |
| serde_cbor 0.11.2 | 2.05 ms | 4.57 ms | 1,407,835 B |
| ciborium 0.2.2 | 3.27 ms | 13.36 ms | 1,407,835 B |

All produce identical CBOR output. cbor4ii is 6.2x faster than ciborium at serialization due to zero-copy serde support and optimized `deserialize_ignored_any`.

### 4.7 Architectural Patterns Summary

**Zero-copy vs. Copy:**
- Zero-copy: Decoded strings/bytes are slices pointing into the input buffer. Lifetime-constrained. Used by minicbor, cbor4ii, QCBOR.
- Copy: Decoded data is owned (`String`, `Vec<u8>`). Required when input is ephemeral. Default in ciborium.

**Streaming vs. DOM-style:**
- Streaming (SAX-like/pull): O(1) memory for traversal. QCBOR sequential decode, minicbor Tokenizer. Best for large payloads or constrained memory.
- DOM-style: Parse into tree (`Value` enum). sk-cbor, ciborium. Simpler API, O(n) memory.
- Hybrid (QCBOR Spiffy Decode): Navigate maps by label without full tree construction.

**Memory Allocation:**
- Caller-supplied buffers (QCBOR, fxamacker `MarshalToBuffer`)
- Buffer reuse/pooling (cbor-x `useBuffer()`)
- Pre-calculated sizes (minicbor `CborLen`)
- Slice views instead of copies (cbor-x `copyBuffers: false`)

**Compile-time vs. Runtime Schema:**
- Compile-time (derive macros): minicbor, ciborium (via serde), Glaze C++
- Runtime: QCBOR Spiffy Decode, fxamacker struct tags

**SIMD:**
- **Glaze (C++):** Applies SSE2/AVX2/NEON to binary format processing including CBOR. ~3.5 GB/s write, ~2.7 GB/s read.
- No dedicated SIMD CBOR library exists (unlike simdjson). CBOR's variable-length initial-byte encoding makes SIMD parallelism harder than for JSON. SIMD can still accelerate: UTF-8 validation, large memcpy, integer conversion.

---

## Sources

- [RFC 8949 — CBOR](https://datatracker.ietf.org/doc/html/rfc8949)
- [RFC 7049 — Original CBOR](https://datatracker.ietf.org/doc/html/rfc7049)
- [cbor.io](https://cbor.io/) — Specification, implementations, tools
- [IANA CBOR Tags Registry](https://www.iana.org/assignments/cbor-tags/cbor-tags.xhtml)
- [cbor.me](https://cbor.me/) — CBOR playground
- [github.com/cbor/test-vectors](https://github.com/cbor/test-vectors)
- [github.com/cabo/cbor-diag](https://github.com/cabo/cbor-diag)
- [github.com/laurencelundblade/QCBOR](https://github.com/laurencelundblade/QCBOR)
- [github.com/kriszyp/cbor-x](https://github.com/kriszyp/cbor-x)
- [github.com/fxamacker/cbor](https://github.com/fxamacker/cbor)
- [docs.rs/minicbor](https://docs.rs/minicbor)
- [crates.io/crates/ciborium](https://crates.io/crates/ciborium)
- [docs.rs/sk-cbor](https://docs.rs/sk-cbor)
- [github.com/djkoloski/rust_serialization_benchmark](https://github.com/djkoloski/rust_serialization_benchmark)
- [Gordian dCBOR Draft](https://datatracker.ietf.org/doc/html/draft-mcnally-deterministic-cbor-05)
- RFC 9052 (COSE), RFC 8392 (CWT), RFC 8610 (CDDL), RFC 8742 (CBOR Sequences)
