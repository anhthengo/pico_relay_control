#Requires -Version 5.1
#Requires -PSEdition Desktop

<#
.SYNOPSIS
Decodes SAM debug-port USP packets using a defmt SAM export XML file.
.DESCRIPTION
Standalone: uses only Windows PowerShell 5.1 and built-in .NET Framework
assemblies. The embedded managed decoder supports defmt wire format v4,
including RZCOBS and raw streams. No SurfDbg DLL, EXE, installation, or network
access is needed. Use an export matching the running firmware.
Logs are written to the pipeline and optionally to a new UTF-8 log file.
Defmt messages include a [TRACE], [DEBUG], [INFO], [WARN], or [ERROR] prefix
when the firmware supplies a level. Unlevelled prints are not assigned a level.
Sequenced USP packets are acknowledged unless -Passive is specified.
No firmware commands, mux changes, or logging-enable commands are sent.
.PARAMETER ComPort
The SAM debug port, as a number (42) or name (COM42).
.PARAMETER SamExportPath
The matching SAM_EXPORT XML containing DefmtData, not an ELF or legacy export.
.PARAMETER InputPath
Replay a binary capture of received USP bytes instead of opening a COM port.
.PARAMETER LogPath
Optional new UTF-8 text log. Existing files are never overwritten or appended.
.PARAMETER RawCapturePath
Optional new binary capture of received serial bytes, including invalid frames.
.PARAMETER IncludePacketDetails
Include every valid USP packet, including ACKs, retransmissions, and fragments.
.PARAMETER Passive
Receive only; do not send ACKs. Intended for a tap with another active receiver.
.PARAMETER EnableDtr
Assert DTR for adapters requiring it (SurfDbg enables this for FireFly RID 10).
RTS remains disabled and hardware flow control is not used.
.PARAMETER PacketTimeoutMilliseconds
Discard an incomplete USP frame after this much serial inactivity.
.PARAMETER LoadTypesOnly
Load the embedded managed types without reading files or opening a port.
Used by the offline tests.
.EXAMPLE
.\Read-SamLog.ps1 -ComPort 42 -SamExportPath C:\Firmware\SAM_EXPORT.xml
.EXAMPLE
.\Read-SamLog.ps1 -ComPort COM42 -SamExportPath C:\Firmware\SAM_EXPORT.xml `
    -LogPath .\sam.log -RawCapturePath .\sam.usp.bin
.EXAMPLE
.\Read-SamLog.ps1 -InputPath .\sam.usp.bin -SamExportPath C:\Firmware\SAM_EXPORT.xml
#>
[CmdletBinding(DefaultParameterSetName = 'Serial')]
param(
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Serial')]
    [ValidatePattern('^(?i:COM)?[1-9][0-9]*$')]
    [string] $ComPort,

    [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Serial')]
    [Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Replay')]
    [ValidateNotNullOrEmpty()]
    [string] $SamExportPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Replay')]
    [ValidateNotNullOrEmpty()]
    [string] $InputPath,

    [string] $LogPath,

    [Parameter(ParameterSetName = 'Serial')]
    [string] $RawCapturePath,

    [Parameter(ParameterSetName = 'Serial')]
    [ValidateRange(1, 2147483647)]
    [int] $BaudRate = 3000000,

    [Parameter(ParameterSetName = 'Serial')]
    [ValidateRange(200, 60000)]
    [int] $PacketTimeoutMilliseconds = 2000,

    [Parameter(ParameterSetName = 'Serial')]
    [switch] $Passive,

    [Parameter(ParameterSetName = 'Serial')]
    [switch] $EnableDtr,

    [switch] $IncludePacketDetails,

    [Parameter(Mandatory = $true, ParameterSetName = 'Types')]
    [switch] $LoadTypesOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$loadedFramer = 'SamDebugLog.UspFramer' -as [type]
if ($null -ne $loadedFramer) {
    $revision = $loadedFramer.GetField('DecoderRevision')
    if ($null -eq $revision -or $revision.GetRawConstantValue() -ne 2) {
        throw 'A different Read-SamLog decoder is already loaded. Open a new Windows PowerShell 5.1 window after updating the script.'
    }
}
if ($null -eq $loadedFramer) {
    Add-Type -Language CSharp -ReferencedAssemblies System.dll, System.Core.dll, System.Xml.dll, System.Numerics.dll, System.Web.Extensions.dll -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Ports;
using System.Numerics;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Xml;

namespace SamDebugLog
{
    public sealed class UspPacket
    {
        public byte Flags;
        public byte Sequence;
        public byte[] Payload;
        public bool IsRetransmission;

        public bool IsControl { get { return (Flags & 0x44) != 0; } }
        public bool NeedsAck { get { return !IsControl && (Flags & 0x80) != 0; } }
        public bool IsSsh { get { return Payload.Length >= 8 && Payload[0] == 0x80; } }
        public bool IsSamDefmt
        {
            get { return !IsControl && IsSsh && Payload[1] == 7 && Payload[3] == 1 && Payload[7] == 0x76; }
        }
        public string StreamKey
        {
            get { return Payload[3] + ":" + Payload[2] + ":" + Payload[4]; }
        }

        public byte[] GetDefmtBytes()
        {
            if (!IsSamDefmt)
                throw new InvalidOperationException("This is not a SAM defmt packet.");
            if (Payload.Length < 10)
                throw new InvalidDataException("DEFMT_BYTES is missing its two-byte length.");
            int length = Payload[8] | (Payload[9] << 8);
            if (length > Payload.Length - 10)
                throw new InvalidDataException("DEFMT_BYTES length exceeds the SSH command data.");
            byte[] data = new byte[length];
            Array.Copy(Payload, 10, data, 0, length);
            return data;
        }

        public string Describe()
        {
            string description = String.Format("USP flags=0x{0:X2} seq={1} length={2}", Flags, Sequence, Payload.Length);
            if (IsSsh)
                description += String.Format(" SSH {0}->{1} iid={2} tc=0x{3:X2} cid=0x{4:X2} req=0x{5:X4}",
                    Payload[3], Payload[2], Payload[4], Payload[1], Payload[7], Payload[5] | (Payload[6] << 8));
            if (IsRetransmission)
                description += " retransmission";
            return description + " payload=" + BitConverter.ToString(Payload).Replace("-", " ");
        }
    }

    public sealed class UspReadItem
    {
        public UspPacket Packet;
        public string Warning;
    }

    public sealed class UspFramer
    {
        public const int DecoderRevision = 2;
        private readonly List<byte> buffer = new List<byte>();
        private UspPacket lastSequenced;
        private static readonly ushort[] crcTable = MakeCrcTable();
        public int BufferedByteCount { get { return buffer.Count; } }

        private static ushort[] MakeCrcTable()
        {
            ushort[] table = new ushort[256];
            for (int i = 0; i < table.Length; i++)
            {
                int value = i << 8;
                for (int bit = 0; bit < 8; bit++)
                    value = ((value << 1) ^ ((value & 0x8000) != 0 ? 0x1021 : 0)) & 0xFFFF;
                table[i] = (ushort)value;
            }
            return table;
        }

        public static ushort Crc16(IList<byte> data, int offset, int count)
        {
            if (data == null || offset < 0 || count < 0 || offset > data.Count - count)
                throw new ArgumentOutOfRangeException("count");
            ushort crc = 0xFFFF;
            for (int i = offset; i < offset + count; i++)
                crc = (ushort)((crc << 8) ^ crcTable[(crc >> 8) ^ data[i]]);
            return crc;
        }

        public static byte[] CreateAck(byte sequence)
        {
            byte[] ack = { 0xAA, 0x55, 0x40, 0, 0, sequence, 0, 0, 0xFF, 0xFF };
            ushort crc = Crc16(ack, 2, 4);
            ack[6] = (byte)crc;
            ack[7] = (byte)(crc >> 8);
            return ack;
        }

        private static bool SamePacket(UspPacket a, UspPacket b)
        {
            if (a == null || a.Sequence != b.Sequence || a.Flags != b.Flags || a.Payload.Length != b.Payload.Length)
                return false;
            for (int i = 0; i < a.Payload.Length; i++)
                if (a.Payload[i] != b.Payload[i]) return false;
            return true;
        }

        public List<UspReadItem> Feed(byte[] data, int count)
        {
            if (data == null || count < 0 || count > data.Length)
                throw new ArgumentOutOfRangeException("count");
            for (int i = 0; i < count; i++) buffer.Add(data[i]);
            List<UspReadItem> items = new List<UspReadItem>();
            int offset = 0, discarded = 0, badHeaders = 0, badPayloads = 0;
            while (buffer.Count - offset >= 2)
            {
                if (buffer[offset] != 0xAA || buffer[offset + 1] != 0x55)
                {
                    offset++;
                    discarded++;
                    continue;
                }
                if (buffer.Count - offset < 8) break;
                int headerCrc = buffer[offset + 6] | (buffer[offset + 7] << 8);
                if (Crc16(buffer, offset + 2, 4) != headerCrc)
                {
                    badHeaders++;
                    discarded++;
                    offset++;
                    continue;
                }
                int length = buffer[offset + 3] | (buffer[offset + 4] << 8);
                // Zero-length packets also have a two-byte (FFFF) payload CRC.
                int packetLength = 8 + length + 2;
                if (buffer.Count - offset < packetLength) break;
                int payloadCrc = buffer[offset + 8 + length] | (buffer[offset + 9 + length] << 8);
                if (Crc16(buffer, offset + 8, length) != payloadCrc)
                {
                    badPayloads++;
                    discarded++;
                    offset++;
                    continue;
                }
                UspPacket packet = new UspPacket {
                    Flags = buffer[offset + 2], Sequence = buffer[offset + 5],
                    Payload = buffer.GetRange(offset + 8, length).ToArray()
                };
                if (packet.NeedsAck)
                {
                    packet.IsRetransmission = SamePacket(lastSequenced, packet);
                    lastSequenced = packet;
                }
                items.Add(new UspReadItem { Packet = packet });
                offset += packetLength;
            }
            if (buffer.Count - offset == 1 && buffer[offset] != 0xAA)
            {
                offset++;
                discarded++;
            }
            if (offset > 0) buffer.RemoveRange(0, offset);
            if (discarded > 0)
                items.Insert(0, new UspReadItem { Warning = String.Format(
                    "Discarded {0} byte(s) while resynchronizing USP; bad header CRCs={1}, bad payload CRCs={2}.",
                    discarded, badHeaders, badPayloads) });
            return items;
        }

        public string DiscardPending()
        {
            string message = "Incomplete USP frame: discarded " + buffer.Count + " buffered byte(s).";
            buffer.Clear();
            return message;
        }

        public List<UspReadItem> RecoverPending()
        {
            if (buffer.Count == 0) return new List<UspReadItem>();
            buffer.RemoveAt(0);
            List<UspReadItem> items = Feed(new byte[0], 0);
            items.Insert(0, new UspReadItem {
                Warning = "Incomplete USP frame abandoned; rescanning buffered bytes for subsequent valid packets."
            });
            return items;
        }
    }

    public sealed class DecodedMessage
    {
        public string Text;
        public bool IsWarning;
        public bool IsFatal;
    }

    internal sealed class FrameError : Exception
    {
        public FrameError(string message) : base(message) { }
    }
    internal sealed class NeedMoreBytes : Exception { }

    internal sealed class DisplayHint
    {
        public string Mode;
        public int Width;
        public bool Alternate;
        public static DisplayHint Parse(string text)
        {
            if (text == null) return null;
            Match match = Regex.Match(text, @"^(#)?(?:0([0-9]+))?(.*)$");
            string mode = match.Groups[3].Value;
            int width = match.Groups[2].Success ? Int32.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture) : 0;
            if (width > 4096) throw new NotSupportedException("Display width exceeds 4096.");
            switch (mode)
            {
                case "": case "?": case "a": case "x": case "X": case "b": case "o":
                case "us": case "ms": case "tus": case "tms": case "ts": case "iso8601ms": case "iso8601s":
                    return new DisplayHint { Mode = mode, Width = width, Alternate = match.Groups[1].Success };
                default: throw new NotSupportedException("Unsupported defmt display hint: " + text);
            }
        }
    }

    internal sealed class WireType
    {
        public string Name;
        public int Bits, Count, Start, End;
        public static WireType Parse(string name)
        {
            WireType type = new WireType { Name = name };
            Match number = Regex.Match(name, @"^[ui](8|16|32|64|128)$");
            if (number.Success)
            {
                type.Bits = Int32.Parse(number.Groups[1].Value, CultureInfo.InvariantCulture);
                return type;
            }
            switch (name)
            {
                case "usize": case "isize": type.Bits = 32; return type;
                case "f32": case "f64": case "bool": case "char": case "str": case "istr":
                case "?": case "[?]": case "[u8]": case "__internal_Debug": case "__internal_Display":
                case "__internal_FormatSequence": return type;
            }
            Match array = Regex.Match(name, @"^\[(\?|u8); *([0-9]+)\]$");
            if (array.Success)
            {
                type.Name = array.Groups[1].Value == "?" ? "format-array" : "byte-array";
                type.Count = Int32.Parse(array.Groups[2].Value, CultureInfo.InvariantCulture);
                if (type.Count > 65536) throw new NotSupportedException("Array exceeds 65536 elements.");
                return type;
            }
            Match bits = Regex.Match(name, @"^([0-9]+)\.\.([0-9]+)$");
            if (bits.Success)
            {
                type.Name = "bits";
                type.Start = Int32.Parse(bits.Groups[1].Value, CultureInfo.InvariantCulture);
                type.End = Int32.Parse(bits.Groups[2].Value, CultureInfo.InvariantCulture);
                if (type.Start < type.End && type.End <= 128) return type;
            }
            throw new NotSupportedException("Unsupported defmt wire type: " + name);
        }
        public bool SameType(WireType other)
        {
            return Name == other.Name && Bits == other.Bits && Count == other.Count;
        }
    }

    internal sealed class FormatPart
    {
        public string Literal;
        public int Index;
        public WireType Type;
        public DisplayHint Hint;
    }

    internal sealed class Template
    {
        public string Text;
        public readonly List<FormatPart> Parts = new List<FormatPart>();
        public readonly List<WireType> Arguments = new List<WireType>();
        public Template(string text)
        {
            Text = text;
            StringBuilder literal = new StringBuilder();
            int nextIndex = 0;
            for (int offset = 0; offset < text.Length; offset++)
            {
                char ch = text[offset];
                if (ch != '{' && ch != '}') { literal.Append(ch); continue; }
                if (offset + 1 < text.Length && text[offset + 1] == ch)
                {
                    literal.Append(ch);
                    offset++;
                    continue;
                }
                if (ch == '}') throw new FormatException("Unescaped closing brace in defmt format.");
                if (literal.Length > 0)
                {
                    Parts.Add(new FormatPart { Literal = literal.ToString() });
                    literal.Clear();
                }
                int end = text.IndexOf('}', offset + 1);
                if (end < 0) throw new FormatException("Unclosed defmt format parameter.");
                string spec = text.Substring(offset + 1, end - offset - 1);
                Match parameter = Regex.Match(spec, @"^([0-9]*)(?:=([^:]+))?(?::(.+))?$");
                if (!parameter.Success) throw new FormatException("Invalid defmt parameter: {" + spec + "}");
                int index = parameter.Groups[1].Length == 0 ? nextIndex++ :
                    Int32.Parse(parameter.Groups[1].Value, CultureInfo.InvariantCulture);
                if (index > 1023) throw new NotSupportedException("Argument index exceeds 1023.");
                WireType type = WireType.Parse(parameter.Groups[2].Success ? parameter.Groups[2].Value : "?");
                DisplayHint hint = DisplayHint.Parse(parameter.Groups[3].Success ? parameter.Groups[3].Value : null);
                Parts.Add(new FormatPart { Index = index, Type = type, Hint = hint });
                while (Arguments.Count <= index) Arguments.Add(null);
                WireType existing = Arguments[index];
                if (existing == null)
                {
                    Arguments[index] = new WireType {
                        Name = type.Name, Bits = type.Bits, Count = type.Count, Start = type.Start, End = type.End
                    };
                }
                else if (!existing.SameType(type)) throw new FormatException("Conflicting types for defmt argument " + index);
                else if (type.Name == "bits")
                {
                    existing.Start = Math.Min(existing.Start, type.Start);
                    existing.End = Math.Max(existing.End, type.End);
                }
                offset = end;
            }
            if (literal.Length > 0) Parts.Add(new FormatPart { Literal = literal.ToString() });
            if (Arguments.Contains(null)) throw new FormatException("Defmt argument indices are not contiguous.");
        }
    }

    internal sealed class Symbol
    {
        public string Tag, Text, Level;
        public Template Plain;
        public Template[] Variants;
        public Template GetPlain()
        {
            if (Plain == null) Plain = new Template(Text);
            return Plain;
        }
    }

    public sealed class DefmtTable
    {
        private readonly Dictionary<int, Symbol> symbols = new Dictionary<int, Symbol>();
        internal Symbol Timestamp;
        public string Encoding { get; private set; }
        public int SymbolCount { get { return symbols.Count; } }
        public int Version { get; private set; }

        public DefmtTable(byte[] xml)
        {
            XmlReaderSettings settings = new XmlReaderSettings();
            settings.DtdProcessing = DtdProcessing.Prohibit;
            settings.XmlResolver = null;
            settings.MaxCharactersInDocument = 64 * 1024 * 1024;
            XmlDocument document = new XmlDocument();
            document.XmlResolver = null;
            using (MemoryStream stream = new MemoryStream(xml))
            using (XmlReader reader = XmlReader.Create(stream, settings))
                document.Load(reader);
            XmlNodeList entries = document.SelectNodes("/root/DefmtData/*");
            if (entries.Count == 0)
                throw new InvalidDataException("The export has no DefmtData. This script requires a defmt SAM export, not a legacy print/trace export.");
            JavaScriptSerializer json = new JavaScriptSerializer();
            foreach (XmlNode entry in entries)
            {
                XmlAttribute value = entry.Attributes["value"];
                if (value == null) throw new InvalidDataException("Defmt symbol is missing its value attribute: " + entry.Name);
                string text = value.Value;
                if (text.StartsWith("_defmt_encoding_ = ", StringComparison.Ordinal))
                {
                    if (Encoding != null) throw new InvalidDataException("Multiple defmt encoding symbols.");
                    Encoding = text.Substring("_defmt_encoding_ = ".Length).Trim();
                    continue;
                }
                if (text.StartsWith("_defmt_version_ = ", StringComparison.Ordinal))
                {
                    if (Version != 0) throw new InvalidDataException("Multiple defmt version symbols.");
                    Version = Int32.Parse(text.Substring("_defmt_version_ = ".Length).Trim(), CultureInfo.InvariantCulture);
                    continue;
                }
                if (text.StartsWith("__DEFMT_MARKER_", StringComparison.Ordinal)) continue;
                if (!text.StartsWith("{", StringComparison.Ordinal))
                    throw new InvalidDataException("Unrecognized defmt metadata: " + text);
                Dictionary<string, object> fields = json.Deserialize<Dictionary<string, object>>(text);
                object tagValue, dataValue;
                if (!fields.TryGetValue("tag", out tagValue) || !(tagValue is string) ||
                    !fields.TryGetValue("data", out dataValue) || !(dataValue is string))
                    throw new InvalidDataException("Defmt symbol requires string tag/data fields: " + entry.Name);
                string tag = (string)tagValue;
                string level = null;
                switch (tag)
                {
                    case "defmt_trace": level = "TRACE"; break;
                    case "defmt_debug": level = "DEBUG"; break;
                    case "defmt_info": level = "INFO"; break;
                    case "defmt_warn": level = "WARN"; break;
                    case "defmt_error": level = "ERROR"; break;
                    case "defmt_prim": case "defmt_derived": case "defmt_write": case "defmt_str":
                    case "defmt_timestamp": case "defmt_println": break;
                    default: throw new NotSupportedException("Unsupported defmt symbol tag: " + tag);
                }
                Match address = Regex.Match(entry.Name, @"^_0[xX]([0-9a-fA-F]+)$");
                if (!address.Success) throw new InvalidDataException("Invalid defmt symbol address: " + entry.Name);
                int id = Int32.Parse(address.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                if (id < 0 || id > 65535) throw new NotSupportedException("Defmt v4 symbol ID exceeds 16 bits.");
                Symbol symbol = new Symbol { Tag = tag, Text = (string)dataValue, Level = level };
                if (tag != "defmt_str")
                {
                    try
                    {
                        if (level == null && tag != "defmt_timestamp" && tag != "defmt_println" && symbol.Text.Contains("|"))
                        {
                            string[] variants = symbol.Text.Split('|');
                            symbol.Variants = new Template[variants.Length];
                            for (int i = 0; i < variants.Length; i++) symbol.Variants[i] = new Template(variants[i]);
                        }
                        else symbol.Plain = new Template(symbol.Text);
                    }
                    catch (Exception error)
                    {
                        if (!(error is FormatException) && !(error is NotSupportedException) && !(error is OverflowException)) throw;
                        throw new InvalidDataException("Invalid/unsupported format at " + entry.Name + ": " + error.Message, error);
                    }
                }
                if (symbols.ContainsKey(id)) throw new InvalidDataException("Duplicate defmt JSON symbol: " + entry.Name);
                symbols.Add(id, symbol);
                if (tag == "defmt_timestamp")
                {
                    if (Timestamp != null) throw new InvalidDataException("Multiple defmt timestamp formats.");
                    Timestamp = symbol;
                }
            }
            if (Version != 4) throw new NotSupportedException("This script supports defmt wire version 4; export version=" + Version);
            if (Encoding != "raw" && Encoding != "rzcobs")
                throw new NotSupportedException("Unsupported or missing defmt stream encoding: " + Encoding);
            if (symbols.Count == 0) throw new InvalidDataException("The export contains no defmt JSON symbols.");
        }
        internal Symbol Get(int id, bool nested)
        {
            Symbol symbol;
            if (!symbols.TryGetValue(id, out symbol)) throw new FrameError("Unknown defmt symbol 0x" + id.ToString("X4") + "; check the firmware/export match.");
            if (nested && symbol.Level != null) throw new FrameError("A log-level symbol was used as an argument format.");
            return symbol;
        }
    }

    internal sealed class Value
    {
        public string Kind;
        public BigInteger Number;
        public string Text;
        public double Float;
        public bool Single;
        public byte[] Bytes;
        public Node Node;
        public List<Node> Nodes;
    }

    internal sealed class Node
    {
        public Template Template;
        public Value[] Values;
    }

    internal sealed class FrameReader
    {
        private static readonly UTF8Encoding utf8 = new UTF8Encoding(false, true);
        private readonly byte[] data;
        private readonly int end;
        private readonly DefmtTable table;
        private int budget = 65536;
        public int Position;
        public int Remaining { get { return end - Position; } }
        public FrameReader(DefmtTable table, byte[] data, int start)
        {
            this.table = table; this.data = data; Position = start; end = data.Length;
        }
        private void Require(int count)
        {
            if (count < 0 || count > DefmtDecoder.MaxFrameBytes) throw new FrameError("Invalid defmt data length.");
            if (count > Remaining) throw new NeedMoreBytes();
        }
        public int U16()
        {
            Require(2); int value = data[Position] | (data[Position + 1] << 8); Position += 2; return value;
        }
        private BigInteger Integer(int bits, bool signed)
        {
            int count = bits / 8;
            Require(count);
            byte[] bytes = new byte[count + (signed ? 0 : 1)];
            Array.Copy(data, Position, bytes, 0, count);
            Position += count;
            return new BigInteger(bytes);
        }
        private int Length(int maximum)
        {
            BigInteger count = Integer(32, false);
            if (count > maximum) throw new FrameError("Defmt length exceeds the safety limit " + maximum + ".");
            return (int)count;
        }
        private byte[] Bytes(int count)
        {
            Require(count);
            byte[] value = new byte[count];
            Array.Copy(data, Position, value, 0, count); Position += count; return value;
        }
        private string Text(int count)
        {
            Require(count);
            try { string text = utf8.GetString(data, Position, count); Position += count; return text; }
            catch (DecoderFallbackException) { throw new FrameError("Invalid UTF-8 in defmt argument."); }
        }
        private Template Variant(Symbol symbol)
        {
            if (symbol.Variants == null) return symbol.GetPlain();
            int bits = symbol.Variants.Length <= 256 ? 8 : (symbol.Variants.Length <= 65536 ? 16 : 32);
            BigInteger index = Integer(bits, false);
            if (index >= symbol.Variants.Length) throw new FrameError("Defmt enum discriminant is out of range.");
            return symbol.Variants[(int)index];
        }
        public Node ReadNode(Template template, int depth)
        {
            if (depth > 64 || --budget < 0) throw new FrameError("Defmt nesting/value budget exceeded.");
            Value[] values = new Value[template.Arguments.Count];
            for (int i = 0; i < values.Length; i++) values[i] = ReadValue(template.Arguments[i], depth + 1);
            return new Node { Template = template, Values = values };
        }
        private Value ReadValue(WireType type, int depth)
        {
            if (--budget < 0) throw new FrameError("Defmt value budget exceeded.");
            if (type.Bits != 0)
                return new Value { Kind = type.Name[0] == 'i' ? "signed" : "number", Number = Integer(type.Bits, type.Name[0] == 'i') };
            switch (type.Name)
            {
                case "bits":
                {
                    int count = (type.End - 1) / 8 - type.Start / 8 + 1;
                    int bits = count <= 1 ? 8 : count <= 2 ? 16 : count <= 4 ? 32 : count <= 8 ? 64 : 128;
                    return new Value { Kind = "number", Number = Integer(bits, false) << (type.Start / 8 * 8) };
                }
                case "f32": return new Value { Kind = "float", Single = true, Float = BitConverter.ToSingle(Bytes(4), 0) };
                case "f64": return new Value { Kind = "float", Float = BitConverter.ToDouble(Bytes(8), 0) };
                case "bool":
                {
                    BigInteger flag = Integer(8, false);
                    if (flag > 1) throw new FrameError("Defmt bool must be 0 or 1.");
                    return new Value { Kind = "literal", Text = flag == 1 ? "true" : "false" };
                }
                case "char":
                {
                    BigInteger code = Integer(32, false);
                    if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) throw new FrameError("Invalid Unicode scalar.");
                    return new Value { Kind = "literal", Text = Char.ConvertFromUtf32((int)code) };
                }
                case "str": return new Value { Kind = "string", Text = Text(Length(DefmtDecoder.MaxFrameBytes)) };
                case "istr": return new Value { Kind = "string", Text = table.Get(U16(), true).Text };
                case "__internal_Debug": case "__internal_Display":
                {
                    int index = Array.IndexOf(data, (byte)0xFF, Position, Remaining);
                    if (index < 0) throw new NeedMoreBytes();
                    string text = Text(index - Position); Position++;
                    return new Value { Kind = "string", Text = text };
                }
                case "[u8]": return new Value { Kind = "bytes", Bytes = Bytes(Length(65536)) };
                case "byte-array": return new Value { Kind = "bytes", Bytes = Bytes(type.Count) };
                case "?": return new Value { Kind = "node", Node = ReadNode(Variant(table.Get(U16(), true)), depth) };
                case "[?]": case "format-array":
                {
                    int count = type.Name == "[?]" ? Length(65536) : type.Count;
                    Symbol symbol = table.Get(U16(), true);
                    List<Node> nodes = new List<Node>();
                    for (int i = 0; i < count; i++) nodes.Add(ReadNode(Variant(symbol), depth));
                    return new Value { Kind = "array", Nodes = nodes };
                }
                case "__internal_FormatSequence":
                {
                    List<Node> nodes = new List<Node>();
                    while (true)
                    {
                        int id = U16();
                        if (id == 0) break;
                        nodes.Add(ReadNode(table.Get(id, true).GetPlain(), depth));
                    }
                    return new Value { Kind = "sequence", Nodes = nodes };
                }
                default: throw new FrameError("Unsupported wire type: " + type.Name);
            }
        }
    }

    internal sealed class Renderer
    {
        private static readonly CultureInfo invariant = CultureInfo.InvariantCulture;
        private static readonly WireType byteType = WireType.Parse("u8");
        private readonly StringBuilder output = new StringBuilder();
        private void Add(string text)
        {
            if (text.Length > DefmtDecoder.MaxFrameBytes - output.Length) throw new FrameError("Decoded text exceeds 1 MiB.");
            output.Append(text);
        }
        public string Finish() { return output.ToString(); }
        public void Literal(string text) { Add(text); }
        private static string Digits(BigInteger value, int radix, bool upper)
        {
            if (value == 0) return "0";
            const string alphabet = "0123456789abcdef";
            StringBuilder digits = new StringBuilder();
            while (value > 0)
            {
                BigInteger remainder;
                value = BigInteger.DivRem(value, radix, out remainder);
                digits.Append(alphabet[(int)remainder]);
            }
            char[] chars = digits.ToString().ToCharArray(); Array.Reverse(chars);
            string text = new string(chars); return upper ? text.ToUpperInvariant() : text;
        }
        private void Number(BigInteger value, WireType type, DisplayHint hint, bool signed)
        {
            string mode = hint == null ? "" : hint.Mode;
            if (!signed && (mode == "us" || mode == "ms" || mode == "tus" || mode == "tms" || mode == "ts"))
            {
                int scale = mode.EndsWith("us", StringComparison.Ordinal) ? 1000000 : mode.EndsWith("ms", StringComparison.Ordinal) ? 1000 : 1;
                BigInteger fraction;
                BigInteger seconds = BigInteger.DivRem(value, scale, out fraction);
                string suffix = scale == 1 ? "" : "." + fraction.ToString(invariant).PadLeft(scale == 1000 ? 3 : 6, '0');
                if (mode[0] != 't') { Add(seconds.ToString(invariant) + suffix); return; }
                BigInteger minutes = seconds / 60, hours = minutes / 60, days = hours / 24;
                Add((days == 0 ? "" : days.ToString(invariant) + ":") +
                    (hours % 24).ToString(invariant).PadLeft(2, '0') + ":" +
                    (minutes % 60).ToString(invariant).PadLeft(2, '0') + ":" +
                    (seconds % 60).ToString(invariant).PadLeft(2, '0') + suffix);
                return;
            }
            if (!signed && (mode == "iso8601ms" || mode == "iso8601s"))
            {
                BigInteger ticks = value * (mode == "iso8601ms" ? 10000 : 10000000);
                DateTime epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
                if (ticks > DateTime.MaxValue.Ticks - epoch.Ticks) throw new FrameError("ISO8601 timestamp exceeds .NET's supported range.");
                Add(epoch.AddTicks((long)ticks).ToString(mode == "iso8601ms" ? "yyyy-MM-dd'T'HH:mm:ss.fff'Z'" : "yyyy-MM-dd'T'HH:mm:ss'Z'", invariant));
                return;
            }
            int radix = mode == "x" || mode == "X" ? 16 : mode == "b" ? 2 : mode == "o" ? 8 : 10;
            bool negative = value < 0;
            string prefix = "";
            if (radix != 10)
            {
                if (negative) value += BigInteger.One << (radix == 16 ? type.Bits : 128);
                if (hint != null && hint.Alternate) prefix = radix == 16 ? "0x" : radix == 2 ? "0b" : "0o";
            }
            else if (negative) { prefix = "-"; value = -value; }
            string digits = Digits(value, radix, mode == "X");
            int width = hint == null ? 0 : hint.Width;
            Add(prefix + digits.PadLeft(Math.Max(0, width - prefix.Length), '0'));
        }
        private static string Quoted(string text, bool bytes)
        {
            StringBuilder result = new StringBuilder(bytes ? "b\"" : "\"");
            foreach (char ch in text)
            {
                switch (ch)
                {
                    case '\t': result.Append("\\t"); break;
                    case '\r': result.Append("\\r"); break;
                    case '\n': result.Append("\\n"); break;
                    case '"': result.Append("\\\""); break;
                    case '\\': result.Append("\\\\"); break;
                    default:
                        if (bytes && (ch < 32 || ch > 126)) result.Append("\\x" + ((int)ch).ToString("x2", invariant));
                        else if (!bytes && ch == 0) result.Append("\\0");
                        else if (Char.IsControl(ch)) result.Append("\\u{" + ((int)ch).ToString("x", invariant) + "}");
                        else result.Append(ch);
                        break;
                }
            }
            return result.Append('"').ToString();
        }
        private void ByteArray(byte[] bytes, DisplayHint hint)
        {
            if (hint != null && hint.Mode == "a")
            {
                char[] chars = new char[bytes.Length];
                for (int i = 0; i < bytes.Length; i++) chars[i] = (char)bytes[i];
                Add(Quoted(new string(chars), true));
                return;
            }
            Add("[");
            for (int i = 0; i < bytes.Length; i++)
            {
                if (i != 0) Add(", ");
                Number(bytes[i], byteType, hint, false);
            }
            Add("]");
        }
        public void Render(Node node, DisplayHint parent, int depth)
        {
            if (depth > 64) throw new FrameError("Defmt rendering depth exceeded.");
            foreach (FormatPart part in node.Template.Parts)
            {
                if (part.Literal != null) { Add(part.Literal); continue; }
                Value value = node.Values[part.Index];
                DisplayHint hint = part.Hint ?? parent;
                switch (value.Kind)
                {
                    case "literal": Add(value.Text); break;
                    case "float":
                    {
                        string text;
                        if (Double.IsNaN(value.Float)) text = "NaN";
                        else if (Double.IsPositiveInfinity(value.Float)) text = "inf";
                        else if (Double.IsNegativeInfinity(value.Float)) text = "-inf";
                        else if (value.Float == 0 && BitConverter.DoubleToInt64Bits(value.Float) < 0) text = "-0.0";
                        else
                        {
                            text = value.Single ? ((float)value.Float).ToString("R", invariant) : value.Float.ToString("R", invariant);
                            text = text.Replace("E", "e");
                            if (!text.Contains(".") && !text.Contains("e")) text += ".0";
                        }
                        Add(text); break;
                    }
                    case "number": case "signed":
                    {
                        BigInteger number = value.Number;
                        if (part.Type.Name == "bits")
                        {
                            number = (number >> part.Type.Start) & ((BigInteger.One << (part.Type.End - part.Type.Start)) - 1);
                            if (hint != null && hint.Mode == "a")
                            {
                                int count = (part.Type.End - part.Type.Start + 7) / 8;
                                byte[] bytes = new byte[count];
                                for (int i = count - 1; i >= 0; i--) { bytes[i] = (byte)(number & 255); number >>= 8; }
                                ByteArray(bytes, hint); break;
                            }
                        }
                        else if (value.Kind == "number" && hint != null && hint.Mode == "?") hint = parent;
                        Number(number, part.Type, hint, value.Kind == "signed"); break;
                    }
                    case "string": Add(hint != null && hint.Mode == "?" ? Quoted(value.Text, false) : value.Text); break;
                    case "bytes": ByteArray(value.Bytes, hint); break;
                    case "node": Render(value.Node, parent != null && parent.Mode == "a" ? parent : hint, depth + 1); break;
                    case "sequence":
                        foreach (Node item in value.Nodes) Render(item, hint, depth + 1);
                        break;
                    case "array":
                    {
                        bool ascii = hint != null && hint.Mode == "a" && value.Nodes.Count > 0;
                        foreach (Node item in value.Nodes) ascii &= item.Template.Text == "{=u8}";
                        if (ascii)
                        {
                            byte[] bytes = new byte[value.Nodes.Count];
                            for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)value.Nodes[i].Values[0].Number;
                            ByteArray(bytes, hint);
                        }
                        else
                        {
                            Add("[");
                            for (int i = 0; i < value.Nodes.Count; i++) { if (i != 0) Add(", "); Render(value.Nodes[i], hint, depth + 1); }
                            Add("]");
                        }
                        break;
                    }
                    default: throw new FrameError("Unknown decoded value kind.");
                }
            }
        }
    }

    public sealed class DefmtDecoder : IDisposable
    {
        public const int MaxFrameBytes = 1024 * 1024;
        private readonly DefmtTable table;
        private readonly List<byte> pending = new List<byte>();
        private bool disposed, faulted, discardUntilDelimiter;
        public string Encoding { get { return table.Encoding; } }
        public int PendingEncodedBytes { get { return pending.Count; } }
        public DefmtDecoder(DefmtTable table)
        {
            if (table == null) throw new ArgumentNullException("table");
            this.table = table;
        }
        public static string InspectExport(byte[] xml) { return new DefmtTable(xml).Encoding; }

        public static byte[] DecodeRzcobs(byte[] encoded)
        {
            if (encoded == null) throw new ArgumentNullException("encoded");
            if (encoded.Length > MaxFrameBytes) throw new FrameError("Encoded RZCOBS frame exceeds 1 MiB.");
            foreach (byte value in encoded)
                if (value == 0) throw new FrameError("Unexpected zero inside an RZCOBS frame.");
            List<byte> reverse = new List<byte>();
            for (int offset = encoded.Length - 1; offset >= 0; )
            {
                int code = encoded[offset--];
                if (code == 0) throw new FrameError("Unexpected zero inside an RZCOBS frame.");
                if (code < 128)
                {
                    for (int bit = 6; bit >= 0; bit--)
                    {
                        if ((code & (1 << bit)) != 0) reverse.Add(0);
                        else
                        {
                            if (offset < 0) throw new FrameError("Truncated RZCOBS zero-mask block.");
                            reverse.Add(encoded[offset--]);
                        }
                    }
                }
                else
                {
                    int count = code == 255 ? 134 : (code & 127) + 7;
                    if (code != 255) reverse.Add(0);
                    if (offset + 1 < count) throw new FrameError("Truncated RZCOBS literal block.");
                    for (int i = 0; i < count; i++) reverse.Add(encoded[offset--]);
                }
                if (reverse.Count > MaxFrameBytes) throw new FrameError("Decoded RZCOBS frame exceeds 1 MiB.");
            }
            reverse.Reverse();
            return reverse.ToArray();
        }
        private string DecodeFrame(byte[] bytes, int start, bool padded, out int consumed)
        {
            FrameReader reader = new FrameReader(table, bytes, start);
            Symbol symbol = table.Get(reader.U16(), false);
            if (symbol.Level == null && symbol.Tag != "defmt_println")
                throw new FrameError("Frame ID does not identify a log message.");
            Node timestamp = table.Timestamp == null ? null : reader.ReadNode(table.Timestamp.GetPlain(), 0);
            Node message = reader.ReadNode(symbol.GetPlain(), 0);
            consumed = reader.Position - start;
            if (padded)
            {
                // A final RZCOBS zero-mask can append up to six padding zeros.
                if (reader.Remaining > 6) throw new FrameError("Unexpected trailing data in the defmt frame.");
                for (int i = reader.Position; i < bytes.Length; i++)
                    if (bytes[i] != 0) throw new FrameError("Nonzero trailing data in the defmt frame.");
            }
            Renderer renderer = new Renderer();
            if (timestamp != null) { renderer.Render(timestamp, null, 0); renderer.Literal(" "); }
            if (symbol.Level != null) renderer.Literal("[" + symbol.Level + "] ");
            renderer.Render(message, null, 0);
            return renderer.Finish();
        }
        private static DecodedMessage Corrupt(string reason, bool fatal)
        {
            return new DecodedMessage {
                IsWarning = true, IsFatal = fatal,
                Text = "Malformed defmt frame: " + reason + " " +
                    (fatal ? "Raw encoding cannot safely resynchronize; restart at a log boundary." :
                        "Dropped this frame; continuing at the next RZCOBS delimiter. Check the export and connection.")
            };
        }
        public List<DecodedMessage> Feed(byte[] bytes)
        {
            if (disposed) throw new ObjectDisposedException("DefmtDecoder");
            if (faulted) throw new InvalidOperationException("The raw defmt stream is faulted.");
            if (bytes == null) throw new ArgumentNullException("bytes");
            List<DecodedMessage> messages = new List<DecodedMessage>();
            if (Encoding == "rzcobs")
            {
                foreach (byte value in bytes)
                {
                    if (discardUntilDelimiter) { if (value == 0) discardUntilDelimiter = false; continue; }
                    if (value != 0)
                    {
                        if (pending.Count == MaxFrameBytes)
                        {
                            pending.Clear(); discardUntilDelimiter = true;
                            messages.Add(Corrupt("Encoded frame exceeded 1 MiB.", false));
                        }
                        else pending.Add(value);
                        continue;
                    }
                    if (pending.Count == 0) continue;
                    try
                    {
                        int consumed;
                        byte[] decoded = DecodeRzcobs(pending.ToArray());
                        messages.Add(new DecodedMessage { Text = DecodeFrame(decoded, 0, true, out consumed) });
                    }
                    catch (NeedMoreBytes) { messages.Add(Corrupt("Incomplete typed arguments.", false)); }
                    catch (FrameError error) { messages.Add(Corrupt(error.Message, false)); }
                    finally { pending.Clear(); }
                }
            }
            else
            {
                if (pending.Count > MaxFrameBytes - bytes.Length)
                {
                    faulted = true;
                    messages.Add(Corrupt("Raw buffer exceeded 1 MiB.", true));
                    return messages;
                }
                pending.AddRange(bytes);
                byte[] data = pending.ToArray();
                int offset = 0;
                while (offset < data.Length)
                {
                    try
                    {
                        int consumed;
                        messages.Add(new DecodedMessage { Text = DecodeFrame(data, offset, false, out consumed) });
                        offset += consumed;
                    }
                    catch (NeedMoreBytes) { break; }
                    catch (FrameError error) { faulted = true; messages.Add(Corrupt(error.Message, true)); break; }
                }
                if (offset > 0) pending.RemoveRange(0, offset);
            }
            return messages;
        }
        public void Dispose() { disposed = true; pending.Clear(); }
    }

    public sealed class SerialErrorMonitor : IDisposable
    {
        private readonly SerialPort port;
        private readonly ConcurrentQueue<SerialError> errors = new ConcurrentQueue<SerialError>();
        public SerialErrorMonitor(SerialPort port)
        {
            this.port = port;
            port.ErrorReceived += OnError;
        }
        private void OnError(object sender, SerialErrorReceivedEventArgs args) { errors.Enqueue(args.EventType); }
        public void ThrowIfError()
        {
            SerialError error;
            if (errors.TryDequeue(out error))
                throw new IOException("Serial receive error: " + error + ". Bytes may have been lost; capture stopped rather than decoding damaged data.");
        }
        public void Dispose() { port.ErrorReceived -= OnError; }
    }
}
'@
}

if ($LoadTypesOnly) { return }

function Resolve-SamInputFile {
    param([string] $Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [System.IO.FileInfo]) { throw "Not a file: $Path" }
    $item.FullName
}

function Write-SamRecord {
    param([string] $Text, [switch] $Warning)
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff zzz} {1}' -f [DateTimeOffset]::Now, $Text.TrimEnd([char[]] "`r`n`0")
    if ($null -ne $logWriter) { $logWriter.WriteLine($line) }
    if ($Warning) { Write-Warning $line } else { Write-Output $line }
}

$exportFile = Resolve-SamInputFile $SamExportPath
if ((Get-Item -LiteralPath $exportFile).Length -gt 64MB) { throw 'SAM export exceeds the 64 MiB safety limit.' }
$exportBytes = [System.IO.File]::ReadAllBytes($exportFile)
$exportTable = New-Object SamDebugLog.DefmtTable -ArgumentList (,$exportBytes)
$encoding = $exportTable.Encoding
$replay = $PSCmdlet.ParameterSetName -eq 'Replay'
if ($replay) { $captureFile = Resolve-SamInputFile $InputPath }

$decoders = @{}
$serial = $null
$monitor = $null
$inputStream = $null
$rawStream = $null
$logWriter = $null
$framer = New-Object SamDebugLog.UspFramer
$buffer = New-Object byte[] 65536
$idleTimer = [System.Diagnostics.Stopwatch]::StartNew()
$truncatedUsp = $false
$captureError = $null

try {
    if ($LogPath) {
        $resolvedLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
        $logStream = [System.IO.File]::Open($resolvedLog, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $logWriter = New-Object System.IO.StreamWriter -ArgumentList $logStream, ([System.Text.UTF8Encoding]::new($false))
        }
        catch {
            $logStream.Dispose()
            throw
        }
        $logWriter.AutoFlush = $true
    }
    if ($replay) {
        $inputStream = [System.IO.File]::OpenRead($captureFile)
        Write-Verbose "Replaying $captureFile; defmt encoding=$encoding"
    }
    else {
        if ($RawCapturePath) {
            $resolvedRaw = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RawCapturePath)
            $rawStream = [System.IO.File]::Open($resolvedRaw, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        }
        $portName = 'COM' + ($ComPort -replace '^(?i:COM)', '')
        $serial = New-Object System.IO.Ports.SerialPort -ArgumentList $portName, $BaudRate, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
        $serial.Handshake = [System.IO.Ports.Handshake]::None
        $serial.DtrEnable = $EnableDtr.IsPresent
        $serial.RtsEnable = $false
        $serial.ReadBufferSize = 1048576
        $serial.ReadTimeout = 200
        $serial.WriteTimeout = 1000
        $monitor = New-Object SamDebugLog.SerialErrorMonitor -ArgumentList $serial
        $serial.Open()
        Write-Host "Listening on $portName at $BaudRate baud, 8N1; defmt=$encoding; passive=$($Passive.IsPresent). Ctrl+C to stop."
    }

    while ($true) {
        $items = $null
        $count = 0
        if ($replay) {
            $count = $inputStream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) {
                if ($framer.BufferedByteCount -gt 0) {
                    $truncatedUsp = $true
                    $items = $framer.RecoverPending()
                }
                else {
                    foreach ($decoder in $decoders.Values) {
                        if ($decoder.PendingEncodedBytes -gt 0) {
                            throw "Capture ended inside a $encoding defmt frame ($($decoder.PendingEncodedBytes) bytes remain)."
                        }
                    }
                    if ($truncatedUsp) { throw 'Incomplete USP frame(s) in the capture; subsequent valid packets were recovered where possible.' }
                    break
                }
            }
        }
        else {
            $monitor.ThrowIfError()
            try {
                $count = $serial.Read($buffer, 0, $buffer.Length)
            }
            catch [System.TimeoutException] {
                $monitor.ThrowIfError()
                if ($framer.BufferedByteCount -gt 0 -and $idleTimer.ElapsedMilliseconds -ge $PacketTimeoutMilliseconds) {
                    $items = $framer.RecoverPending()
                }
                else { continue }
            }
            if ($count -gt 0) {
                $idleTimer.Restart()
                if ($null -ne $rawStream) {
                    $rawStream.Write($buffer, 0, $count)
                    $rawStream.Flush()
                }
            }
            $monitor.ThrowIfError()
        }

        if ($null -eq $items) { $items = $framer.Feed($buffer, $count) }
        foreach ($item in $items) {
            if ($null -ne $item.Warning) {
                Write-SamRecord -Text $item.Warning -Warning
                continue
            }
            $packet = $item.Packet
            if ($packet.NeedsAck -and -not $replay -and -not $Passive) {
                $ack = [SamDebugLog.UspFramer]::CreateAck($packet.Sequence)
                $serial.Write($ack, 0, $ack.Length)
            }
            if ($IncludePacketDetails) { Write-SamRecord -Text ($packet.Describe()) }
            if (($packet.Flags -band 0x04) -ne 0) {
                Write-SamRecord -Text ('Received USP NACK. ' + $packet.Describe()) -Warning
            }
            if ($packet.IsControl -or $packet.IsRetransmission) { continue }
            if ($packet.IsSamDefmt) {
                $key = $packet.StreamKey
                if (-not $decoders.ContainsKey($key)) {
                    $decoders[$key] = New-Object SamDebugLog.DefmtDecoder -ArgumentList $exportTable
                }
                foreach ($message in $decoders[$key].Feed($packet.GetDefmtBytes())) {
                    Write-SamRecord -Text $message.Text -Warning:$message.IsWarning
                    if ($message.IsFatal) { throw $message.Text }
                }
            }
            elseif ($packet.IsSsh -and $packet.Payload[1] -eq 7 -and $packet.Payload[7] -eq 6) {
                Write-SamRecord -Text ([System.Text.Encoding]::UTF8.GetString($packet.Payload, 8, $packet.Payload.Length - 8))
            }
            elseif (-not $IncludePacketDetails) {
                # Never decode another MCU's defmt bytes with SAM's export, or silently drop unknown packets.
                Write-SamRecord -Text ($packet.Describe())
            }
        }
    }
}
catch {
    $captureError = $_
    throw
}
finally {
    $cleanupErrors = New-Object 'System.Collections.Generic.List[System.Exception]'
    foreach ($resource in (@($monitor, $serial, $inputStream, $rawStream, $logWriter) + @($decoders.Values))) {
        if ($null -eq $resource) { continue }
        try { $resource.Dispose() }
        catch {
            # Finish closing the other resources before reporting cleanup failures.
            $cleanupErrors.Add($_.Exception)
        }
    }
    if ($cleanupErrors.Count -gt 0) {
        if ($null -ne $captureError) { $cleanupErrors.Insert(0, $captureError.Exception) }
        throw [System.AggregateException]::new('Errors while closing the SAM capture.', $cleanupErrors)
    }
}
