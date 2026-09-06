using System.Numerics;
using System.IO.Compression;
using Zstandard.Net;

const string pakPath = @"D:\SteamLibrary\steamapps\common\MonsterHunterRise\re_chunk_000.pak";
const string outputPath = @"F:\ruanjian\guailiemod\MHR-mod-repository\analysis\raw\natives\STM\player\Fsm\Bow\Bow.motfsm2.43";
const uint targetLower = 3357464497;
const uint targetUpper = 3902412028;

byte[] modulus = {
    0x7D,0x0B,0xF8,0xC1,0x7C,0x23,0xFD,0x3B,0xD4,0x75,0x16,0xD2,0x33,0x21,0xD8,0x10,
    0x71,0xF9,0x7C,0xD1,0x34,0x93,0xBA,0x77,0x26,0xFC,0xAB,0x2C,0xEE,0xDA,0xD9,0x1C,
    0x89,0xE7,0x29,0x7B,0xDD,0x8A,0xAE,0x50,0x39,0xB6,0x01,0x6D,0x21,0x89,0x5D,0xA5,
    0xA1,0x3E,0xA2,0xC0,0x8C,0x93,0x13,0x36,0x65,0xEB,0xE8,0xDF,0x06,0x17,0x67,0x96,
    0x06,0x2B,0xAC,0x23,0xED,0x8C,0xB7,0x8B,0x90,0xAD,0xEA,0x71,0xC4,0x40,0x44,0x9D,
    0x1C,0x7B,0xBA,0xC4,0xB6,0x2D,0xD6,0xD2,0x4B,0x62,0xD6,0x26,0xFC,0x74,0x20,0x07,
    0xEC,0xE3,0x59,0x9A,0xE6,0xAF,0xB9,0xA8,0x35,0x8B,0xE0,0xE8,0xD3,0xCD,0x45,0x65,
    0xB0,0x91,0xC4,0x95,0x1B,0xF3,0x23,0x1E,0xC6,0x71,0xCF,0x3E,0x35,0x2D,0x6B,0xE3,0x00
};
byte[] exponent = { 1, 0, 1, 0 };

using var stream = File.OpenRead(pakPath);
using var reader = new BinaryReader(stream);
if (reader.ReadUInt32() != 0x414B504B) throw new InvalidDataException("Not a Rise PAK");
var major = reader.ReadByte();
reader.ReadByte();
var feature = reader.ReadInt16();
var totalFiles = reader.ReadInt32();
reader.ReadUInt32();
if (major != 4 || feature != 8) throw new InvalidDataException("Unsupported PAK header");

var entryBytes = reader.ReadBytes(totalFiles * 48);
var encryptedKey = reader.ReadBytes(128);
var keyInput = encryptedKey.Concat(new byte[] { 0 }).ToArray();
var key = BigInteger.ModPow(new BigInteger(keyInput), new BigInteger(exponent), new BigInteger(modulus)).ToByteArray();
for (var i = 0; i < entryBytes.Length; i++)
    entryBytes[i] = (byte)(entryBytes[i] ^ (byte)(i + key[i % 32] * key[i % 29]));

long offset = 0, compressedSize = 0, decompressedSize = 0;
for (var i = 0; i < totalFiles; i++) {
    var p = i * 48;
    if (BitConverter.ToUInt32(entryBytes, p) != targetLower || BitConverter.ToUInt32(entryBytes, p + 4) != targetUpper) continue;
    offset = BitConverter.ToInt64(entryBytes, p + 8);
    compressedSize = BitConverter.ToInt64(entryBytes, p + 16);
    decompressedSize = BitConverter.ToInt64(entryBytes, p + 24);
    break;
}
if (offset == 0 || compressedSize == 0) throw new FileNotFoundException("Bow FSM entry not found");

stream.Position = offset;
var compressed = reader.ReadBytes(checked((int)compressedSize));
using var compressedStream = new MemoryStream(compressed);
using var zstd = new ZstandardStream(compressedStream, CompressionMode.Decompress);
using var output = new MemoryStream();
zstd.CopyTo(output);
var data = output.ToArray();
if (data.LongLength != decompressedSize) throw new InvalidDataException($"Size mismatch: {data.LongLength} != {decompressedSize}");
Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
File.WriteAllBytes(outputPath, data);
Console.WriteLine($"Extracted {outputPath} ({data.Length} bytes)");
