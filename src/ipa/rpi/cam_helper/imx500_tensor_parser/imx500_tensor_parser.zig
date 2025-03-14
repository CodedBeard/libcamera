const std = @import("std");
const log = @import("log");
const Span = @import("span");

const TensorType = enum {
    InputTensor,
    OutputTensor,
    Kpi,
};

const Dimensions = struct {
    ordinal: u8,
    size: u16,
    serializationIndex: u8,
    padding: u8,
};

const IMX500OutputTensorInfo = struct {
    totalSize: u32,
    numTensors: u32,
    networkName: []const u8,
    data: std.mem.Allocator,
    tensorDataNum: []u32,
    vecDim: [][]Dimensions,
    numDimensions: []u32,
};

const IMX500InputTensorInfo = struct {
    width: u32,
    height: u32,
    widthStride: u32,
    heightStride: u32,
    channels: u32,
    size: u32,
    networkName: []const u8,
    data: std.mem.Allocator,
};

const IMX500Tensors = struct {
    valid: bool,
    offset: u32,
};

fn imx500ParseOutputTensor(outputTensorInfo: *IMX500OutputTensorInfo, outputTensor: Span) !void {
    var dnnHeader: DnnHeader = undefined;
    var apParams: []u8 = undefined;
    var outputApParams: []OutputTensorApParams = undefined;

    const src = outputTensor.data;
    try parseHeader(&dnnHeader, &apParams, src);

    if (dnnHeader.tensorType != TensorType.OutputTensor) {
        return error.InvalidTensorType;
    }

    try parseOutputApParams(&outputApParams, apParams, dnnHeader);
    try populateOutputTensorInfo(outputTensorInfo, outputApParams);
    try parseOutputTensorBody(outputTensorInfo, src + TensorStride, outputApParams, dnnHeader);
}

fn imx500ParseInputTensor(inputTensorInfo: *IMX500InputTensorInfo, inputTensor: Span) !void {
    var dnnHeader: DnnHeader = undefined;
    var apParams: []u8 = undefined;
    var inputApParams: InputTensorApParams = undefined;

    const src = inputTensor.data;
    try parseHeader(&dnnHeader, &apParams, src);

    if (dnnHeader.tensorType != TensorType.InputTensor) {
        return error.InvalidTensorType;
    }

    try parseInputApParams(&inputApParams, apParams, dnnHeader);
    try parseInputTensorBody(inputTensorInfo, src + TensorStride, inputApParams, dnnHeader);
}

fn imx500SplitTensors(tensors: Span) std.UnorderedMap(TensorType, IMX500Tensors) {
    var offsets = std.UnorderedMap(TensorType, IMX500Tensors).init(std.heap.page_allocator);

    const outputHeader = tensors.data + TensorStride;
    var inputHeader: DnnHeader = undefined;
    inputHeader = @ptrCast(*const DnnHeader, outputHeader);

    if (inputHeader.tensorType != TensorType.InputTensor) {
        log.debug("Input tensor is invalid, aborting.");
        return offsets;
    }

    offsets.put(TensorType.Kpi, IMX500Tensors{ .offset = 0, .valid = false });
    offsets.put(TensorType.InputTensor, IMX500Tensors{ .offset = TensorStride, .valid = inputHeader.frameValid });

    var src = tensors.data + 2 * TensorStride;
    while (src < tensors.data + tensors.len) {
        const outputHeader = @ptrCast(*const DnnHeader, src);
        if (outputHeader.frameCount == inputHeader.frameCount &&
            outputHeader.apParamSize == inputHeader.apParamSize &&
            outputHeader.maxLineLen == inputHeader.maxLineLen &&
            outputHeader.tensorType == TensorType.OutputTensor) {
            offsets.put(TensorType.OutputTensor, IMX500Tensors{ .offset = src - tensors.data, .valid = outputHeader.frameValid });
            break;
        }
        src += TensorStride;
    }

    return offsets;
}
