const std = @import("std");
const Span = std.mem.Span;

pub const MdParser = struct {
    pub const Status = enum {
        OK,
        NOTFOUND,
        ERROR,
    };

    pub const RegisterMap = std.StringHashMap(u32);

    pub fn init() MdParser {
        return MdParser{
            .reset = true,
            .bitsPerPixel = 0,
            .numLines = 0,
            .lineLengthBytes = 0,
        };
    }

    pub fn reset(self: *MdParser) void {
        self.reset = true;
    }

    pub fn setBitsPerPixel(self: *MdParser, bpp: i32) void {
        self.bitsPerPixel = bpp;
    }

    pub fn setNumLines(self: *MdParser, numLines: u32) void {
        self.numLines = numLines;
    }

    pub fn setLineLengthBytes(self: *MdParser, numBytes: u32) void {
        self.lineLengthBytes = numBytes;
    }

    pub fn parse(self: *MdParser, buffer: Span(const u8), registers: *RegisterMap) Status {
        return self.vtable.parse(self, buffer, registers);
    }

    reset: bool,
    bitsPerPixel: i32,
    numLines: u32,
    lineLengthBytes: u32,
    vtable: *const MdParserVTable,
};

const MdParserVTable = struct {
    parse: fn(self: *MdParser, buffer: Span(const u8), registers: *MdParser.RegisterMap) MdParser.Status,
};

pub const MdParserSmia = struct {
    pub const ParseStatus = enum {
        ParseOk,
        MissingRegs,
        NoLineStart,
        IllegalTag,
        BadDummy,
        BadLineEnd,
        BadPadding,
    };

    pub fn init(registerList: []const u32) MdParserSmia {
        var offsets = std.StringHashMap(std.Option(u32)).init(std.heap.page_allocator);
        for (register in registerList) {
            offsets.put(register, std.Option(u32).none);
        }
        return MdParserSmia{
            .base = MdParser.init(),
            .offsets = offsets,
        };
    }

    pub fn parse(self: *MdParserSmia, buffer: Span(const u8), registers: *MdParser.RegisterMap) MdParser.Status {
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
        if (buffer[0] != 0x0a) {
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
                if (buffer[currentOffset] != 0x55) {
                    return .BadDummy;
                }
                currentOffset += 1;
            }

            const dataByte = buffer[currentOffset];
            currentOffset += 1;

            if (tag == 0x07) {
                if (dataByte != 0x07) {
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

                    if (buffer[currentOffset] != 0x0a) {
                        return .NoLineStart;
                    }
                } else {
                    while (currentOffset < buffer.len and buffer[currentOffset] != 0x0a) {
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
                if (tag == 0xaa) {
                    regNum = (regNum & 0xff) | (dataByte << 8);
                } else if (tag == 0xa5) {
                    regNum = (regNum & 0xff00) | dataByte;
                } else if (tag == 0x55) {
                    regNum += 1;
                } else if (tag == 0x5a) {
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

    base: MdParser,
    offsets: std.StringHashMap(std.Option(u32)),
};
