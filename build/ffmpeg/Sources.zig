//! Shape of the per-library source lists tools/ffmpeg_extract.py writes to gen/ffmpeg/.

pub const CGroup = struct {
    /// Extra include dirs, relative to the FFmpeg tree.
    includes: []const []const u8,
    files: []const []const u8,
};

pub const Library = struct {
    name: []const u8,
    c: []const CGroup,
    nasm: []const []const u8,
    gas: []const []const u8,
    cuda: []const []const u8,
    /// Public headers, by basename inside the library's directory.
    headers: []const []const u8,
};
