const std = @import("std");
const log = @import("log");
const Span = std.mem.Span;

const MdParser = @import("md_parser.zig").MdParser;
const RegisterMap = MdParser.RegisterMap;

const LineStart: u32 = 0x0a;
const LineEndTag: u32 = 0x07;
const RegHiBits: u32 = 0xaa;
const RegLowBits: u32 = 0xa5;
const RegValue: u32 = 0x5a;
const RegSkip: u32 = 0x55;

const MdParserSmia = struct {
    base: MdParser,
    offsets: std.StringHashMap(std.Option(u32)),

    pub fn new(registerList: []const u32) MdParserSmia {
        var offsets = std.StringHashMap(std.Option(u32)).init(std.heap.page_allocator);
        for (register in registerList) {
            offsets.put(register, std.Option(u32).none);
        }
        return MdParserSmia{
            .base = MdParser.init(),
            .offsets = offsets,
        };
    }

    pub fn parse(self: *MdParserSmia, buffer: Span(const u8), registers: *RegisterMap) MdParser.Status {
        if (self.base.reset) {
            for (kv in self.offsets.items()) {
                self.offsets.put(kv.key, std.Option(u32).none);
            }

            const ret = self.findRegs(buffer);
            if (ret != .ParseOk) {
                return MdParser.Status.ERROR;
            }

            self.base.reset = false;
        }

        registers.clear();
        for (kv in self.offsets.items()) {
            if (!kv.value) {
                self.base.reset = true;
                return MdParser.Status.NOTFOUND;
            }
            registers.put(kv.key, kv.value.?.value);
        }

        return MdParser.Status.OK;
    }

    fn findRegs(self: *MdParserSmia, buffer: Span(const u8)) ParseStatus {
        if (buffer[0] != LineStart) {
            return .NoLineStart;
        }

        var currentOffset: u32 = 1;
        var currentLineStart: u32 = 0;
        var currentLine: u32 = 0;
        var regNum: u32 = 0;
        var regsDone: u32 = 0;

        while (true) {
            const tag = buffer[currentOffset];
            currentOffset += 1;

            while ((self.base.bitsPerPixel == 10 and (currentOffset + 1 - currentLineStart) % 5 == 0) or
                   (self.base.bitsPerPixel == 12 and (currentOffset + 1 - currentLineStart) % 3 == 0) or
                   (self.base.bitsPerPixel == 14 and (currentOffset - currentLineStart) % 7 >= 4)) {
                if (buffer[currentOffset] != RegSkip) {
                    return .BadDummy;
                }
                currentOffset += 1;
            }

            const dataByte = buffer[currentOffset];
            currentOffset += 1;

            if (tag == LineEndTag) {
                if (dataByte != LineEndTag) {
                    return .BadLineEnd;
                }

                if (self.base.numLines != 0 and currentLine + 1 == self.base.numLines) {
                    return .MissingRegs;
                }

                if (self.base.lineLengthBytes != 0) {
                    currentOffset = currentLineStart + self.base.lineLengthBytes;

                    if (buffer.len != 0 and currentOffset + self.base.lineLengthBytes > buffer.len) {
                        return .MissingRegs;
                    }

                    if (buffer[currentOffset] != LineStart) {
                        return .NoLineStart;
                    }
                } else {
                    while (currentOffset < buffer.len and buffer[currentOffset] != LineStart) {
                        currentOffset += 1;
                    }

                    if (currentOffset == buffer.len) {
                        return .NoLineStart;
                    }
                }

                currentLineStart = currentOffset;
                currentOffset += 1;
                currentLine += 1;
            } else {
                if (tag == RegHiBits) {
                    regNum = (regNum & 0xff) | (dataByte << 8);
                } else if (tag == RegLowBits) {
                    regNum = (regNum & 0xff00) | dataByte;
                } else if (tag == RegSkip) {
                    regNum += 1;
                } else if (tag == RegValue) {
                    if (self.offsets.contains(regNum)) {
                        self.offsets.put(regNum, std.Option(u32).some(currentOffset - 1));
                        regsDone += 1;
                        if (regsDone == self.offsets.size()) {
                            return .ParseOk;
                        }
                    }
                    regNum += 1;
                } else {
                    return .IllegalTag;
                }
            }
        }
    }

    pub const ParseStatus = enum {
        ParseOk,
        MissingRegs,
        NoLineStart,
        IllegalTag,
        BadDummy,
        BadLineEnd,
        BadPadding,
    };
};
