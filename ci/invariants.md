# Invariants checked by the cleanup pass

- `KeyParser` owns no memory: `start <= end <= buffer.len`, the buffer meets
  `min_buffer`, and compaction preserves exactly the unread prefix. Iterators
  advance these bounds; pending reads and public feed/flush/reset use them.
- `Stripper` retains only an incomplete UTF-8 prefix of one to three bytes,
  in text state. Its leading byte determines a longer sequence of at most four
  bytes. Feeding and finishing cannot produce more bytes than their input plus
  the previously retained prefix; finishing restores the initial state.
- Base64 uses a 64-character alphabet and a 256-byte reverse map. Whole groups
  consume three bytes and write four characters. Decoding requires canonical
  padding and writes exactly `decodedLen` bytes, with fewer than eight residual
  bits after each character.
- Capability names and values are even-length ASCII hex, established by the
  reply parser and checked again by the decoder before indexing pairs.
- Placeholder indices fit the protocol's diacritic table; every table entry
  and the placeholder itself is a Unicode scalar, and the table covers every
  possible image-id top byte.
- SGR cost writers discard output without errors. Their counts fit the declared
  maximum sequence size, which also bounds the scratch used for style diffs.
- Escape framing starts on ESC and returns either an incomplete frame or a
  positive prefix length. CSI parameter/intermediate transitions and control
  string terminators are separate grammar states.
- Writers and their cost functions share the same spelling; existing byte,
  round-trip, split-input and fuzz tests check their relationship. Packed
  mouse modes hold two 16-bit settings in 32 bits.
