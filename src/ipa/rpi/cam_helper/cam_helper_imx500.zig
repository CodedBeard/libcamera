const std = @import("std");
const log = @import("log");
const span = @import("span");

const CamHelper = @import("cam_helper").CamHelper;
const MdParser = @import("md_parser").MdParser;
const MdParserSmia = @import("md_parser").MdParserSmia;
const Metadata = @import("metadata").Metadata;
const DeviceStatus = @import("device_status").DeviceStatus;
const Duration = @import("duration").Duration;
const RegisterCamHelper = @import("register_cam_helper").RegisterCamHelper;
const IMX500Tensors = @import("imx500_tensor_parser").IMX500Tensors;
const TensorType = @import("imx500_tensor_parser").TensorType;
const imx500SplitTensors = @import("imx500_tensor_parser").imx500SplitTensors;
const imx500ParseInputTensor = @import("imx500_tensor_parser").imx500ParseInputTensor;
const imx500ParseOutputTensor = @import("imx500_tensor_parser").imx500ParseOutputTensor;
const CnnInputTensorInfo = @import("cnn_input_tensor_info").CnnInputTensorInfo;
const CnnOutputTensorInfo = @import("cnn_output_tensor_info").CnnOutputTensorInfo;
const CnnKpiInfo = @import("cnn_kpi_info").CnnKpiInfo;

const expHiReg: u32 = 0x0202;
const expLoReg: u32 = 0x0203;
const gainHiReg: u32 = 0x0204;
const gainLoReg: u32 = 0x0205;
const frameLengthHiReg: u32 = 0x0340;
const frameLengthLoReg: u32 = 0x0341;
const lineLengthHiReg: u32 = 0x0342;
const lineLengthLoReg: u32 = 0x0343;
const temperatureReg: u32 = 0x013a;
const registerList = [_]u32{ expHiReg, expLoReg, gainHiReg, gainLoReg, frameLengthHiReg, frameLengthLoReg,
                             lineLengthHiReg, lineLengthLoReg, temperatureReg };

const frameIntegrationDiff: i32 = 22;
const frameLengthMax: i32 = 0xffdc;
const longExposureShiftMax: i32 = 7;

const CamHelperImx500 = struct {
    base: CamHelper,
    savedInputTensor: ?[]u8,

    pub fn new() CamHelperImx500 {
        return CamHelperImx500{
            .base = CamHelper.new(MdParserSmia.new(registerList), frameIntegrationDiff),
            .savedInputTensor = null,
        };
    }

    pub fn gainCode(self: *CamHelperImx500, gain: f64) u32 {
        return @intCast(u32, 1024 - 1024 / gain);
    }

    pub fn gain(self: *CamHelperImx500, gainCode: u32) f64 {
        return 1024.0 / (1024 - gainCode);
    }

    pub fn prepare(self: *CamHelperImx500, buffer: span.Span(u8), metadata: *Metadata) void {
        var deviceStatus: DeviceStatus = undefined;

        if (metadata.get("device.status", &deviceStatus)) {
            log.error("DeviceStatus not found from DelayedControls");
            return;
        }

        self.base.parseEmbeddedData(buffer, metadata);

        if (deviceStatus.frameLength > frameLengthMax) {
            var parsedDeviceStatus: DeviceStatus = undefined;

            metadata.get("device.status", &parsedDeviceStatus);
            parsedDeviceStatus.exposureTime = deviceStatus.exposureTime;
            parsedDeviceStatus.frameLength = deviceStatus.frameLength;
            metadata.set("device.status", &parsedDeviceStatus);

            log.debug("Metadata updated for long exposure: {}", .{parsedDeviceStatus});
        }

        self.parseInferenceData(buffer, metadata);
    }

    pub fn getBlanking(self: *CamHelperImx500, exposure: *Duration, minFrameDuration: Duration, maxFrameDuration: Duration) !std.builtin.Pair(u32, u32) {
        var frameLength: u32 = 0;
        var exposureLines: u32 = 0;
        var shift: u32 = 0;

        var blanking = self.base.getBlanking(exposure, minFrameDuration, maxFrameDuration);
        frameLength = self.base.mode.height + blanking.first;
        var lineLength = self.base.hblankToLineLength(blanking.second);

        while (frameLength > frameLengthMax) {
            if (shift += 1 > longExposureShiftMax) {
                shift = longExposureShiftMax;
                frameLength = frameLengthMax;
                break;
            }
            frameLength >>= 1;
        }

        if (shift != 0) {
            frameLength <<= shift;
            exposureLines = self.base.exposureLines(*exposure, lineLength);
            exposureLines = std.math.min(exposureLines, frameLength - frameIntegrationDiff);
            *exposure = self.base.exposure(exposureLines, lineLength);
        }

        return std.builtin.Pair(u32, u32){ .first = frameLength - self.base.mode.height, .second = blanking.second };
    }

    pub fn sensorEmbeddedDataPresent(self: *CamHelperImx500) bool {
        return true;
    }

    fn parseInferenceData(self: *CamHelperImx500, buffer: span.Span(u8), metadata: *Metadata) void {
        const StartLine: usize = 2;
        var bytesPerLine = (self.base.mode.width * self.base.mode.bitdepth) >> 3;
        if (self.base.hwConfig.dataBufferStrided) {
            bytesPerLine = (bytesPerLine + 15) & ~15;
        }

        if (buffer.len <= StartLine * bytesPerLine) {
            return;
        }

        var enableInputTensor: bool = false;
        metadata.get("cnn.enable_input_tensor", &enableInputTensor);

        var tensorBufferSize = buffer.len - (StartLine * bytesPerLine);
        var cache = std.heap.c_allocator.alloc(u8, tensorBufferSize) catch return;
        std.mem.copy(u8, cache, buffer.ptr + StartLine * bytesPerLine, tensorBufferSize);
        var tensors = span.Span(u8){ .ptr = cache, .len = tensorBufferSize };

        var offsets = imx500SplitTensors(tensors);
        var itIn = offsets.get(TensorType.InputTensor);
        var itOut = offsets.get(TensorType.OutputTensor);

        if (itIn != null and itOut != null) {
            const inputTensorOffset = itIn.offset;
            const outputTensorOffset = itOut.offset;
            const inputTensorSize = outputTensorOffset - inputTensorOffset;
            var inputTensor: span.Span(u8) = undefined;

            if (itIn.valid) {
                if (itOut.valid) {
                    inputTensor = span.Span(u8){ .ptr = cache + inputTensorOffset, .len = inputTensorSize };
                } else {
                    self.savedInputTensor = std.heap.c_allocator.alloc(u8, inputTensorSize) catch return;
                    std.mem.copy(u8, self.savedInputTensor, cache + inputTensorOffset, inputTensorSize);
                }
            } else if (itOut.valid and self.savedInputTensor != null) {
                inputTensor = span.Span(u8){ .ptr = self.savedInputTensor, .len = inputTensorSize };
            }

            if (inputTensor.len != 0) {
                var inputTensorInfo: IMX500InputTensorInfo = undefined;
                if (!imx500ParseInputTensor(&inputTensorInfo, inputTensor)) {
                    var exported: CnnInputTensorInfo = undefined;
                    exported.width = inputTensorInfo.width;
                    exported.height = inputTensorInfo.height;
                    exported.numChannels = inputTensorInfo.channels;
                    std.mem.copy(u8, &exported.networkName, inputTensorInfo.networkName.ptr, std.math.min(inputTensorInfo.networkName.len, exported.networkName.len));
                    metadata.set("cnn.input_tensor_info", &exported);
                    metadata.set("cnn.input_tensor", inputTensorInfo.data);
                    metadata.set("cnn.input_tensor_size", inputTensorInfo.size);
                }

                self.savedInputTensor = null;
            }
        }

        if (itOut != null and itOut.valid) {
            const outputTensorOffset = itOut.offset;
            var outputTensor = span.Span(u8){ .ptr = cache + outputTensorOffset, .len = tensorBufferSize - outputTensorOffset };

            var outputTensorInfo: IMX500OutputTensorInfo = undefined;
            if (!imx500ParseOutputTensor(&outputTensorInfo, outputTensor)) {
                var exported: CnnOutputTensorInfo = undefined;
                if (outputTensorInfo.numTensors < MaxNumTensors) {
                    exported.numTensors = outputTensorInfo.numTensors;
                    for (var i: usize = 0; i < exported.numTensors; i += 1) {
                        exported.info[i].tensorDataNum = outputTensorInfo.tensorDataNum[i];
                        exported.info[i].numDimensions = outputTensorInfo.numDimensions[i];
                        for (var j: usize = 0; j < exported.info[i].numDimensions; j += 1) {
                            exported.info[i].size[j] = outputTensorInfo.vecDim[i][j].size;
                        }
                    }
                } else {
                    log.debug("IMX500 output tensor info export failed, numTensors > MaxNumTensors");
                }
                std.mem.copy(u8, &exported.networkName, outputTensorInfo.networkName.ptr, std.math.min(outputTensorInfo.networkName.len, exported.networkName.len));
                metadata.set("cnn.output_tensor_info", &exported);
                metadata.set("cnn.output_tensor", outputTensorInfo.data);
                metadata.set("cnn.output_tensor_size", outputTensorInfo.totalSize);

                var itKpi = offsets.get(TensorType.Kpi);
                if (itKpi != null) {
                    const DnnRuntimeOffset: usize = 9;
                    const DspRuntimeOffset: usize = 10;
                    var kpi: CnnKpiInfo = undefined;

                    var k = cache + itKpi.offset;
                    kpi.dnnRuntime = k[4 * DnnRuntimeOffset + 3] << 24 |
                                     k[4 * DnnRuntimeOffset + 2] << 16 |
                                     k[4 * DnnRuntimeOffset + 1] << 8 |
                                     k[4 * DnnRuntimeOffset];
                    kpi.dspRuntime = k[4 * DspRuntimeOffset + 3] << 24 |
                                     k[4 * DspRuntimeOffset + 2] << 16 |
                                     k[4 * DspRuntimeOffset + 1] << 8 |
                                     k[4 * DspRuntimeOffset];
                    metadata.set("cnn.kpi_info", &kpi);
                }
            }
        }
    }

    pub fn populateMetadata(self: *CamHelperImx500, registers: MdParser.RegisterMap, metadata: *Metadata) void {
        var deviceStatus: DeviceStatus = undefined;

        deviceStatus.lineLength = self.base.lineLengthPckToDuration(registers.get(lineLengthHiReg) * 256 + registers.get(lineLengthLoReg));
        deviceStatus.exposureTime = self.base.exposure(registers.get(expHiReg) * 256 + registers.get(expLoReg), deviceStatus.lineLength);
        deviceStatus.analogueGain = self.gain(registers.get(gainHiReg) * 256 + registers.get(gainLoReg));
        deviceStatus.frameLength = registers.get(frameLengthHiReg) * 256 + registers.get(frameLengthLoReg);
        deviceStatus.sensorTemperature = std.math.clamp(@intCast(i8, registers.get(temperatureReg)), -20, 80);

        metadata.set("device.status", &deviceStatus);
    }
};

fn create() *CamHelper {
    return CamHelperImx500.new();
}

const reg_imx500 = RegisterCamHelper.new("imx500", create);
