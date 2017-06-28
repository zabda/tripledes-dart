library tripledes;

import 'dart:typed_data';
import 'dart:math';



/// BufferedBlockAlgorithm.process()
abstract class BaseEngine {
  int processBlock(List<int> M, int offset);

  List<int> process(List<int> dataWords) {
    var doFlush = false;
    var dataSigBytes = dataWords.length;
    var blockSize = 2;
    var blockSizeBytes = blockSize * 4;
    var minBufferSize = 0;

    // Count blocks ready
    var nBlocksReady = dataSigBytes ~/ blockSizeBytes;
    if (doFlush) {
      // Round up to include partial blocks
      nBlocksReady = nBlocksReady.ceil();
    } else {
      // Round down to include only full blocks,
      // less the number of blocks that must remain in the buffer
      nBlocksReady = max((nBlocksReady | 0) - minBufferSize, 0);
    }

    // Count words ready
    var nWordsReady = nBlocksReady * blockSize;

    // Count bytes ready
    var nBytesReady = min(nWordsReady * 4, dataSigBytes);

    // Process blocks
    List<int> processedWords;
    if (nWordsReady != 0) {
      for (var offset = 0; offset < nWordsReady; offset += blockSize) {
        // Perform concrete-algorithm logic
        processBlock(dataWords, offset);
      }

      // Remove processed words
      processedWords = dataWords.getRange(0, nWordsReady).toList();
      dataWords.removeRange(0, nWordsReady);
    }
    return new List<int>.generate(nBytesReady, (i) {
      if (i < processedWords.length) {
        return processedWords[i];
      }
      return 0;
    });
  }
}

class DESEngine extends BaseEngine {
  bool _forEncryption;
  List<int> _key;
  List<List<int>> _subKeys;
  int _lBlock;
  int _rBlock;

  String get algorithmName => "DES";

  int get blockSize => 64 ~/ 32;

  void init(bool forEncryption, List<int> key) {
    _key = key;
    this._forEncryption = forEncryption;

    // Select 56 bits according to PC1
    var keyBits = new List<int>(56);
    for (var i = 0; i < 56; i++) {
      var keyBitPos = PC1[i] - 1;
      keyBits[i] = (rightShift32(
              _key[rightShift32(keyBitPos, 5)], (31 - keyBitPos % 32))) &
          1;
    }

    // Assemble 16 subkeys
    var subKeys = this._subKeys = new List<List<int>>.generate(16, (_) => []);
    for (var nSubKey = 0; nSubKey < 16; nSubKey++) {
      // Create subkey
      var subKey = subKeys[nSubKey] = new List.generate(24, (_) => 0);

      // Shortcut
      var bitShift = BIT_SHIFTS[nSubKey];

      // Select 48 bits according to PC2
      for (var i = 0; i < 24; i++) {
        // Select from the left 28 key bits
        subKey[(i ~/ 6) | 0] |=
            leftShift32(keyBits[((PC2[i] - 1) + bitShift) % 28], (31 - i % 6));

        // Select from the right 28 key bits
        subKey[4 + ((i ~/ 6) | 0)] |= leftShift32(
            keyBits[28 + (((PC2[i + 24] - 1) + bitShift) % 28)], (31 - i % 6));
      }

      // Since each subkey is applied to an expanded 32-bit input,
      // the subkey can be broken into 8 values scaled to 32-bits,
      // which allows the key to be used without expansion
      subKey[0] = (subKey[0] << 1).toSigned(32) | rightShift32(subKey[0], 31);
      for (var i = 1; i < 7; i++) {
        subKey[i] = rightShift32(subKey[i], ((i - 1) * 4 + 3));
      }
      subKey[7] = (subKey[7] << 5).toSigned(32) | (rightShift32(subKey[7], 27));
    }
  }

  int processBlock(List<int> M, int offset) {
    List<List<int>> invSubKeys = new List(16);
    if (!_forEncryption) {
      for (var i = 0; i < 16; i++) {
        invSubKeys[i] = _subKeys[15 - i];
      }
    }

    List<List<int>> subKeys = _forEncryption ? _subKeys : invSubKeys;

    this._lBlock = M[offset].toSigned(32);
    this._rBlock = M[offset + 1].toSigned(32);
    // Initial permutation
    exchangeLR(4, 0x0f0f0f0f);
    exchangeLR(16, 0x0000ffff);
    exchangeRL(2, 0x33333333);
    exchangeRL(8, 0x00ff00ff);
    exchangeLR(1, 0x55555555);

    // Rounds
    for (var round = 0; round < 16; round++) {
      // Shortcuts
      var subKey = subKeys[round];
      var lBlock = this._lBlock;
      var rBlock = this._rBlock;

      // Feistel function
      var f = 0.toSigned(32);
      for (var i = 0; i < 8; i++) {
        (f |= (SBOX_P[i][((rBlock ^ subKey[i]).toSigned(32) & SBOX_MASK[i]).toUnsigned(32)]).toSigned(32)).toSigned(32);
      }
      this._lBlock = rBlock.toSigned(32);
      this._rBlock = (lBlock ^ f).toSigned(32);
    }

    // Undo swap from last round
    var t = this._lBlock;
    this._lBlock = this._rBlock;
    this._rBlock = t;

    // Final permutation
    exchangeLR(1, 0x55555555);
    exchangeRL(8, 0x00ff00ff);
    exchangeRL(2, 0x33333333);
    exchangeLR(16, 0x0000ffff);
    exchangeLR(4, 0x0f0f0f0f);

    // Set output
    M[offset] = this._lBlock;
    M[offset + 1] = this._rBlock;
    return blockSize;
  }

  void reset() {
    _forEncryption = false;
    _key = null;
    _subKeys = null;
    _lBlock = null;
    _rBlock = null;
  }

  // Swap bits across the left and right words
  void exchangeLR(offset, mask) {
    var t =
        (((rightShift32(this._lBlock, offset)).toSigned(32) ^ this._rBlock) &
                mask)
            .toSigned(32);
    (this._rBlock ^= t).toSigned(32);
    this._lBlock ^= (t << offset).toSigned(32);
  }

  void exchangeRL(offset, mask) {
    var t =
        (((rightShift32(this._rBlock, offset)).toSigned(32) ^ this._lBlock) &
                mask)
            .toSigned(32);
    (this._lBlock ^= t).toSigned(32);
    this._rBlock ^= (t << offset).toSigned(32);
  }
}

class TripleDESEngine extends BaseEngine {
  List<int> _key;
  bool _forEncryption;

  String get algorithmName => "TripleDES";

  int get blockSize => 64 ~/ 32;

  void init(bool forEncryption, List<int> key) {
    _forEncryption = forEncryption;
    _key = key;
  }

  int processBlock(List<int> M, int offset) {
    var des1 = new DESEngine();
    var des2 = new DESEngine();
    var des3 = new DESEngine();
    if (_forEncryption) {
      des1.init(true, _key.sublist(0, 2));
      des1.processBlock(M, offset);
      des2.init(false, _key.sublist(2, 4));
      des2.processBlock(M, offset);
      des3.init(true, _key.sublist(4, 6));
      des3.processBlock(M, offset);
    } else {
      des3.init(false, _key.sublist(4, 6));
      des3.processBlock(M, offset);
      des2.init(true, _key.sublist(2, 4));
      des2.processBlock(M, offset);
      des1.init(false, _key.sublist(0, 2));
      des1.processBlock(M, offset);
    }
    return blockSize;
  }

  void reset() {
    _key = null;
    _forEncryption = false;
  }
}

// Permuted Choice 1 constants
var PC1 = [
  57,
  49,
  41,
  33,
  25,
  17,
  9,
  1,
  58,
  50,
  42,
  34,
  26,
  18,
  10,
  2,
  59,
  51,
  43,
  35,
  27,
  19,
  11,
  3,
  60,
  52,
  44,
  36,
  63,
  55,
  47,
  39,
  31,
  23,
  15,
  7,
  62,
  54,
  46,
  38,
  30,
  22,
  14,
  6,
  61,
  53,
  45,
  37,
  29,
  21,
  13,
  5,
  28,
  20,
  12,
  4
];

// Permuted Choice 2 constants
var PC2 = [
  14,
  17,
  11,
  24,
  1,
  5,
  3,
  28,
  15,
  6,
  21,
  10,
  23,
  19,
  12,
  4,
  26,
  8,
  16,
  7,
  27,
  20,
  13,
  2,
  41,
  52,
  31,
  37,
  47,
  55,
  30,
  40,
  51,
  45,
  33,
  48,
  44,
  49,
  39,
  56,
  34,
  53,
  46,
  42,
  50,
  36,
  29,
  32
];

// Cumulative bit shift constants
var BIT_SHIFTS = [1, 2, 4, 6, 8, 10, 12, 14, 15, 17, 19, 21, 23, 25, 27, 28];

// SBOXes and round permutation constants
var SBOX_P = [
  {
    0x0: 0x808200,
    0x10000000: 0x8000,
    0x20000000: 0x808002,
    0x30000000: 0x2,
    0x40000000: 0x200,
    0x50000000: 0x808202,
    0x60000000: 0x800202,
    0x70000000: 0x800000,
    0x80000000: 0x202,
    0x90000000: 0x800200,
    0xa0000000: 0x8200,
    0xb0000000: 0x808000,
    0xc0000000: 0x8002,
    0xd0000000: 0x800002,
    0xe0000000: 0x0,
    0xf0000000: 0x8202,
    0x8000000: 0x0,
    0x18000000: 0x808202,
    0x28000000: 0x8202,
    0x38000000: 0x8000,
    0x48000000: 0x808200,
    0x58000000: 0x200,
    0x68000000: 0x808002,
    0x78000000: 0x2,
    0x88000000: 0x800200,
    0x98000000: 0x8200,
    0xa8000000: 0x808000,
    0xb8000000: 0x800202,
    0xc8000000: 0x800002,
    0xd8000000: 0x8002,
    0xe8000000: 0x202,
    0xf8000000: 0x800000,
    0x1: 0x8000,
    0x10000001: 0x2,
    0x20000001: 0x808200,
    0x30000001: 0x800000,
    0x40000001: 0x808002,
    0x50000001: 0x8200,
    0x60000001: 0x200,
    0x70000001: 0x800202,
    0x80000001: 0x808202,
    0x90000001: 0x808000,
    0xa0000001: 0x800002,
    0xb0000001: 0x8202,
    0xc0000001: 0x202,
    0xd0000001: 0x800200,
    0xe0000001: 0x8002,
    0xf0000001: 0x0,
    0x8000001: 0x808202,
    0x18000001: 0x808000,
    0x28000001: 0x800000,
    0x38000001: 0x200,
    0x48000001: 0x8000,
    0x58000001: 0x800002,
    0x68000001: 0x2,
    0x78000001: 0x8202,
    0x88000001: 0x8002,
    0x98000001: 0x800202,
    0xa8000001: 0x202,
    0xb8000001: 0x808200,
    0xc8000001: 0x800200,
    0xd8000001: 0x0,
    0xe8000001: 0x8200,
    0xf8000001: 0x808002
  },
  {
    0x0: 0x40084010,
    0x1000000: 0x4000,
    0x2000000: 0x80000,
    0x3000000: 0x40080010,
    0x4000000: 0x40000010,
    0x5000000: 0x40084000,
    0x6000000: 0x40004000,
    0x7000000: 0x10,
    0x8000000: 0x84000,
    0x9000000: 0x40004010,
    0xa000000: 0x40000000,
    0xb000000: 0x84010,
    0xc000000: 0x80010,
    0xd000000: 0x0,
    0xe000000: 0x4010,
    0xf000000: 0x40080000,
    0x800000: 0x40004000,
    0x1800000: 0x84010,
    0x2800000: 0x10,
    0x3800000: 0x40004010,
    0x4800000: 0x40084010,
    0x5800000: 0x40000000,
    0x6800000: 0x80000,
    0x7800000: 0x40080010,
    0x8800000: 0x80010,
    0x9800000: 0x0,
    0xa800000: 0x4000,
    0xb800000: 0x40080000,
    0xc800000: 0x40000010,
    0xd800000: 0x84000,
    0xe800000: 0x40084000,
    0xf800000: 0x4010,
    0x10000000: 0x0,
    0x11000000: 0x40080010,
    0x12000000: 0x40004010,
    0x13000000: 0x40084000,
    0x14000000: 0x40080000,
    0x15000000: 0x10,
    0x16000000: 0x84010,
    0x17000000: 0x4000,
    0x18000000: 0x4010,
    0x19000000: 0x80000,
    0x1a000000: 0x80010,
    0x1b000000: 0x40000010,
    0x1c000000: 0x84000,
    0x1d000000: 0x40004000,
    0x1e000000: 0x40000000,
    0x1f000000: 0x40084010,
    0x10800000: 0x84010,
    0x11800000: 0x80000,
    0x12800000: 0x40080000,
    0x13800000: 0x4000,
    0x14800000: 0x40004000,
    0x15800000: 0x40084010,
    0x16800000: 0x10,
    0x17800000: 0x40000000,
    0x18800000: 0x40084000,
    0x19800000: 0x40000010,
    0x1a800000: 0x40004010,
    0x1b800000: 0x80010,
    0x1c800000: 0x0,
    0x1d800000: 0x4010,
    0x1e800000: 0x40080010,
    0x1f800000: 0x84000
  },
  {
    0x0: 0x104,
    0x100000: 0x0,
    0x200000: 0x4000100,
    0x300000: 0x10104,
    0x400000: 0x10004,
    0x500000: 0x4000004,
    0x600000: 0x4010104,
    0x700000: 0x4010000,
    0x800000: 0x4000000,
    0x900000: 0x4010100,
    0xa00000: 0x10100,
    0xb00000: 0x4010004,
    0xc00000: 0x4000104,
    0xd00000: 0x10000,
    0xe00000: 0x4,
    0xf00000: 0x100,
    0x80000: 0x4010100,
    0x180000: 0x4010004,
    0x280000: 0x0,
    0x380000: 0x4000100,
    0x480000: 0x4000004,
    0x580000: 0x10000,
    0x680000: 0x10004,
    0x780000: 0x104,
    0x880000: 0x4,
    0x980000: 0x100,
    0xa80000: 0x4010000,
    0xb80000: 0x10104,
    0xc80000: 0x10100,
    0xd80000: 0x4000104,
    0xe80000: 0x4010104,
    0xf80000: 0x4000000,
    0x1000000: 0x4010100,
    0x1100000: 0x10004,
    0x1200000: 0x10000,
    0x1300000: 0x4000100,
    0x1400000: 0x100,
    0x1500000: 0x4010104,
    0x1600000: 0x4000004,
    0x1700000: 0x0,
    0x1800000: 0x4000104,
    0x1900000: 0x4000000,
    0x1a00000: 0x4,
    0x1b00000: 0x10100,
    0x1c00000: 0x4010000,
    0x1d00000: 0x104,
    0x1e00000: 0x10104,
    0x1f00000: 0x4010004,
    0x1080000: 0x4000000,
    0x1180000: 0x104,
    0x1280000: 0x4010100,
    0x1380000: 0x0,
    0x1480000: 0x10004,
    0x1580000: 0x4000100,
    0x1680000: 0x100,
    0x1780000: 0x4010004,
    0x1880000: 0x10000,
    0x1980000: 0x4010104,
    0x1a80000: 0x10104,
    0x1b80000: 0x4000004,
    0x1c80000: 0x4000104,
    0x1d80000: 0x4010000,
    0x1e80000: 0x4,
    0x1f80000: 0x10100
  },
  {
    0x0: 0x80401000,
    0x10000: 0x80001040,
    0x20000: 0x401040,
    0x30000: 0x80400000,
    0x40000: 0x0,
    0x50000: 0x401000,
    0x60000: 0x80000040,
    0x70000: 0x400040,
    0x80000: 0x80000000,
    0x90000: 0x400000,
    0xa0000: 0x40,
    0xb0000: 0x80001000,
    0xc0000: 0x80400040,
    0xd0000: 0x1040,
    0xe0000: 0x1000,
    0xf0000: 0x80401040,
    0x8000: 0x80001040,
    0x18000: 0x40,
    0x28000: 0x80400040,
    0x38000: 0x80001000,
    0x48000: 0x401000,
    0x58000: 0x80401040,
    0x68000: 0x0,
    0x78000: 0x80400000,
    0x88000: 0x1000,
    0x98000: 0x80401000,
    0xa8000: 0x400000,
    0xb8000: 0x1040,
    0xc8000: 0x80000000,
    0xd8000: 0x400040,
    0xe8000: 0x401040,
    0xf8000: 0x80000040,
    0x100000: 0x400040,
    0x110000: 0x401000,
    0x120000: 0x80000040,
    0x130000: 0x0,
    0x140000: 0x1040,
    0x150000: 0x80400040,
    0x160000: 0x80401000,
    0x170000: 0x80001040,
    0x180000: 0x80401040,
    0x190000: 0x80000000,
    0x1a0000: 0x80400000,
    0x1b0000: 0x401040,
    0x1c0000: 0x80001000,
    0x1d0000: 0x400000,
    0x1e0000: 0x40,
    0x1f0000: 0x1000,
    0x108000: 0x80400000,
    0x118000: 0x80401040,
    0x128000: 0x0,
    0x138000: 0x401000,
    0x148000: 0x400040,
    0x158000: 0x80000000,
    0x168000: 0x80001040,
    0x178000: 0x40,
    0x188000: 0x80000040,
    0x198000: 0x1000,
    0x1a8000: 0x80001000,
    0x1b8000: 0x80400040,
    0x1c8000: 0x1040,
    0x1d8000: 0x80401000,
    0x1e8000: 0x400000,
    0x1f8000: 0x401040
  },
  {
    0x0: 0x80,
    0x1000: 0x1040000,
    0x2000: 0x40000,
    0x3000: 0x20000000,
    0x4000: 0x20040080,
    0x5000: 0x1000080,
    0x6000: 0x21000080,
    0x7000: 0x40080,
    0x8000: 0x1000000,
    0x9000: 0x20040000,
    0xa000: 0x20000080,
    0xb000: 0x21040080,
    0xc000: 0x21040000,
    0xd000: 0x0,
    0xe000: 0x1040080,
    0xf000: 0x21000000,
    0x800: 0x1040080,
    0x1800: 0x21000080,
    0x2800: 0x80,
    0x3800: 0x1040000,
    0x4800: 0x40000,
    0x5800: 0x20040080,
    0x6800: 0x21040000,
    0x7800: 0x20000000,
    0x8800: 0x20040000,
    0x9800: 0x0,
    0xa800: 0x21040080,
    0xb800: 0x1000080,
    0xc800: 0x20000080,
    0xd800: 0x21000000,
    0xe800: 0x1000000,
    0xf800: 0x40080,
    0x10000: 0x40000,
    0x11000: 0x80,
    0x12000: 0x20000000,
    0x13000: 0x21000080,
    0x14000: 0x1000080,
    0x15000: 0x21040000,
    0x16000: 0x20040080,
    0x17000: 0x1000000,
    0x18000: 0x21040080,
    0x19000: 0x21000000,
    0x1a000: 0x1040000,
    0x1b000: 0x20040000,
    0x1c000: 0x40080,
    0x1d000: 0x20000080,
    0x1e000: 0x0,
    0x1f000: 0x1040080,
    0x10800: 0x21000080,
    0x11800: 0x1000000,
    0x12800: 0x1040000,
    0x13800: 0x20040080,
    0x14800: 0x20000000,
    0x15800: 0x1040080,
    0x16800: 0x80,
    0x17800: 0x21040000,
    0x18800: 0x40080,
    0x19800: 0x21040080,
    0x1a800: 0x0,
    0x1b800: 0x21000000,
    0x1c800: 0x1000080,
    0x1d800: 0x40000,
    0x1e800: 0x20040000,
    0x1f800: 0x20000080
  },
  {
    0x0: 0x10000008,
    0x100: 0x2000,
    0x200: 0x10200000,
    0x300: 0x10202008,
    0x400: 0x10002000,
    0x500: 0x200000,
    0x600: 0x200008,
    0x700: 0x10000000,
    0x800: 0x0,
    0x900: 0x10002008,
    0xa00: 0x202000,
    0xb00: 0x8,
    0xc00: 0x10200008,
    0xd00: 0x202008,
    0xe00: 0x2008,
    0xf00: 0x10202000,
    0x80: 0x10200000,
    0x180: 0x10202008,
    0x280: 0x8,
    0x380: 0x200000,
    0x480: 0x202008,
    0x580: 0x10000008,
    0x680: 0x10002000,
    0x780: 0x2008,
    0x880: 0x200008,
    0x980: 0x2000,
    0xa80: 0x10002008,
    0xb80: 0x10200008,
    0xc80: 0x0,
    0xd80: 0x10202000,
    0xe80: 0x202000,
    0xf80: 0x10000000,
    0x1000: 0x10002000,
    0x1100: 0x10200008,
    0x1200: 0x10202008,
    0x1300: 0x2008,
    0x1400: 0x200000,
    0x1500: 0x10000000,
    0x1600: 0x10000008,
    0x1700: 0x202000,
    0x1800: 0x202008,
    0x1900: 0x0,
    0x1a00: 0x8,
    0x1b00: 0x10200000,
    0x1c00: 0x2000,
    0x1d00: 0x10002008,
    0x1e00: 0x10202000,
    0x1f00: 0x200008,
    0x1080: 0x8,
    0x1180: 0x202000,
    0x1280: 0x200000,
    0x1380: 0x10000008,
    0x1480: 0x10002000,
    0x1580: 0x2008,
    0x1680: 0x10202008,
    0x1780: 0x10200000,
    0x1880: 0x10202000,
    0x1980: 0x10200008,
    0x1a80: 0x2000,
    0x1b80: 0x202008,
    0x1c80: 0x200008,
    0x1d80: 0x0,
    0x1e80: 0x10000000,
    0x1f80: 0x10002008
  },
  {
    0x0: 0x100000,
    0x10: 0x2000401,
    0x20: 0x400,
    0x30: 0x100401,
    0x40: 0x2100401,
    0x50: 0x0,
    0x60: 0x1,
    0x70: 0x2100001,
    0x80: 0x2000400,
    0x90: 0x100001,
    0xa0: 0x2000001,
    0xb0: 0x2100400,
    0xc0: 0x2100000,
    0xd0: 0x401,
    0xe0: 0x100400,
    0xf0: 0x2000000,
    0x8: 0x2100001,
    0x18: 0x0,
    0x28: 0x2000401,
    0x38: 0x2100400,
    0x48: 0x100000,
    0x58: 0x2000001,
    0x68: 0x2000000,
    0x78: 0x401,
    0x88: 0x100401,
    0x98: 0x2000400,
    0xa8: 0x2100000,
    0xb8: 0x100001,
    0xc8: 0x400,
    0xd8: 0x2100401,
    0xe8: 0x1,
    0xf8: 0x100400,
    0x100: 0x2000000,
    0x110: 0x100000,
    0x120: 0x2000401,
    0x130: 0x2100001,
    0x140: 0x100001,
    0x150: 0x2000400,
    0x160: 0x2100400,
    0x170: 0x100401,
    0x180: 0x401,
    0x190: 0x2100401,
    0x1a0: 0x100400,
    0x1b0: 0x1,
    0x1c0: 0x0,
    0x1d0: 0x2100000,
    0x1e0: 0x2000001,
    0x1f0: 0x400,
    0x108: 0x100400,
    0x118: 0x2000401,
    0x128: 0x2100001,
    0x138: 0x1,
    0x148: 0x2000000,
    0x158: 0x100000,
    0x168: 0x401,
    0x178: 0x2100400,
    0x188: 0x2000001,
    0x198: 0x2100000,
    0x1a8: 0x0,
    0x1b8: 0x2100401,
    0x1c8: 0x100401,
    0x1d8: 0x400,
    0x1e8: 0x2000400,
    0x1f8: 0x100001
  },
  {
    0x0: 0x8000820,
    0x1: 0x20000,
    0x2: 0x8000000,
    0x3: 0x20,
    0x4: 0x20020,
    0x5: 0x8020820,
    0x6: 0x8020800,
    0x7: 0x800,
    0x8: 0x8020000,
    0x9: 0x8000800,
    0xa: 0x20800,
    0xb: 0x8020020,
    0xc: 0x820,
    0xd: 0x0,
    0xe: 0x8000020,
    0xf: 0x20820,
    0x80000000: 0x800,
    0x80000001: 0x8020820,
    0x80000002: 0x8000820,
    0x80000003: 0x8000000,
    0x80000004: 0x8020000,
    0x80000005: 0x20800,
    0x80000006: 0x20820,
    0x80000007: 0x20,
    0x80000008: 0x8000020,
    0x80000009: 0x820,
    0x8000000a: 0x20020,
    0x8000000b: 0x8020800,
    0x8000000c: 0x0,
    0x8000000d: 0x8020020,
    0x8000000e: 0x8000800,
    0x8000000f: 0x20000,
    0x10: 0x20820,
    0x11: 0x8020800,
    0x12: 0x20,
    0x13: 0x800,
    0x14: 0x8000800,
    0x15: 0x8000020,
    0x16: 0x8020020,
    0x17: 0x20000,
    0x18: 0x0,
    0x19: 0x20020,
    0x1a: 0x8020000,
    0x1b: 0x8000820,
    0x1c: 0x8020820,
    0x1d: 0x20800,
    0x1e: 0x820,
    0x1f: 0x8000000,
    0x80000010: 0x20000,
    0x80000011: 0x800,
    0x80000012: 0x8020020,
    0x80000013: 0x20820,
    0x80000014: 0x20,
    0x80000015: 0x8020000,
    0x80000016: 0x8000000,
    0x80000017: 0x8000820,
    0x80000018: 0x8020820,
    0x80000019: 0x8000020,
    0x8000001a: 0x8000800,
    0x8000001b: 0x0,
    0x8000001c: 0x20800,
    0x8000001d: 0x820,
    0x8000001e: 0x20020,
    0x8000001f: 0x8020800
  }
];

// Masks that select the SBOX input
var SBOX_MASK = [
  0xf8000001,
  0x1f800000,
  0x01f80000,
  0x001f8000,
  0x0001f800,
  0x00001f80,
  0x000001f8,
  0x8000001f
];

int rightShift32(int num, int n) {
  return ((num & 0xFFFFFFFF) >> n).toSigned(32);
}

int leftShift32(int num, int n) {
  return ((num & 0xFFFFFFFF) << n).toSigned(32);
}

Uint8List uInt8ListFrom32BitList(List<int> bit32) {
  var result = new Uint8List(bit32.length * 4);
  for (var i = 0; i < bit32.length; i++) {
    for (var j = 0; j < 4; j++) {
      result[i * 4 + j] = bit32[i] /*.toSigned(32)*/ >> (j * 8);
    }
  }
  return result;
}

List<int> bit32ListFromUInt8List(Uint8List bytes) {
  var additionalLength = bytes.length % 4 > 0 ? 4 : 0;
  var result =
      new List<int>.generate(bytes.length ~/ 4 + additionalLength, (_) => 0);
  for (var i = 0; i < bytes.length; i++) {
    var resultIdx = i ~/ 4;
    var bitShiftAmount = (3 - i % 4);
    result[resultIdx] |= bytes[i] << bitShiftAmount;
  }
  for (var i = 0; i < result.length; i++) {
    result[i] = result[i] << 24;
  }
  return result;
}

void pkcs7Pad(List<int> data, int blockSize) {
  var blockSizeBytes = blockSize * 4;
  // Count padding bytes
  var nPaddingBytes = blockSizeBytes - data.length % blockSizeBytes;

  // Create padding word
  var paddingWord = (nPaddingBytes << 24) |
  (nPaddingBytes << 16) |
  (nPaddingBytes << 8) |
  nPaddingBytes;

  // Create padding
  var paddingWords = [];
  for (var i = 0; i < nPaddingBytes; i += 4) {
    paddingWords.add(paddingWord);
  }

  var padding = new List<int>.generate(nPaddingBytes, (i) {
    if (i < paddingWords.length) {
      return paddingWords[i];
    } else {
      return 0;
    }
  });

  // Add padding
  concat(data, padding);
}

/// wordarray.concat()
concat(List<int> a, List<int> b) {
  // Shortcuts
  var thisWords = a;
  var thatWords = b;
  var thisSigBytes = a.length;
  var thatSigBytes = b.length;

  // Clamp excess bits
  clamp(a);

  // Concat
  if (thisSigBytes % 4 != 0) {
    // Copy one byte at a time
    for (var i = 0; i < thatSigBytes; i++) {
      var thatByte = (thatWords[i >> 2] >> (24 - (i % 4) * 8)) & 0xff;
      thisWords[(thisSigBytes + i) >> 2] |= thatByte << (24 - ((thisSigBytes + i) % 4) * 8);
    }
  } else {
    // Copy one word at a time
    for (var i = 0; i < thatSigBytes; i += 4) {
      var idx = (thisSigBytes + i) >> 2;
      if (idx >= thisWords.length) {
        thisWords.length = idx + 1;
      }
      thisWords[idx] = thatWords[i >> 2];
    }
  }
  a.length = thisSigBytes + thatSigBytes;
}

void clamp(List<int> data) {
  // Shortcuts
  var words = data;
  var sigBytes = data.length;

  // Clamp
  words[rightShift32(sigBytes, 2)] &= (0xffffffff << (32 - (sigBytes % 4) * 8)).toSigned(32);
  words.length = (sigBytes / 4).ceil();
}

// Latin1.parse
List<int> encodeWordArray(String inp) {
  var words = new List.generate(inp.length, (_) => 0);
  for (var i = 0; i < inp.length; i++) {
    words[i >> 2] |= (inp.codeUnitAt(i) & 0xff).toSigned(32) <<
        (24 - (i % 4) * 8).toSigned(32);
  }
  return words;
  // lib-typedarrays WordArray.init()
  /*
  var resultWords = [];
  for (var i = 0; i < words.length; i++) {
    var idx = rightShift32(i, 2);
    if (resultWords.length < idx + 1) {
      resultWords.length = idx + 1;
      for (var j = 0; j < resultWords.length; j++) {
        if (resultWords[j] == null) resultWords[j] = 0;
      }
//      resultWords[idx] |= words[i] << (24 - (i % 4) * 8);
    }
//    resultWords[idx] = words[i];
  }
  return resultWords;
  */
}

// Latin1.stringify
String decodeWordArray(List<int> words) {
  var sigBytes = words.length;
  var chars = <int>[];
  for (var i = 0; i < sigBytes; i++) {
    if (words[i >> 2] == null) {
      words[i >> 2] = 0;
    }
    var bite = ((words[i >> 2]).toSigned(32) >> (24 - (i % 4) * 8)) & 0xff;
    chars.add(bite);
  }

  return new String.fromCharCodes(chars);
}

void process() {

}