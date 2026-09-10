const std = @import("std");

pub fn build(b: *std.Build) !void {
    const src = b.dependency("protobuf_src", .{});

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const abseil = b.dependency("abseil", .{ .target = target, .optimize = optimize });

    // Grab the sources.json which tells us what to build
    const io = b.graph.io;
    const source_content = src.builder.build_root.handle.readFileAlloc(
        io,
        "src/file_lists.cmake",
        b.allocator,
        .unlimited,
    ) catch @panic("OOM");

    // utf8 validity
    const utf8_validity = b.addLibrary(.{
        .name = "utf8_validity",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    utf8_validity.root_module.addCSourceFile(.{
        .file = src.path("third_party/utf8_range/utf8_range.c"),
    });
    utf8_validity.root_module.addIncludePath(src.path("third_party/utf8_range"));
    utf8_validity.installHeadersDirectory(src.path("third_party/utf8_range/"), "", .{});

    // lib protobuf
    const lib_protobuf_src = try getFiles(b, source_content, "# @//pkg:protobuf\n");
    const lib_protobuf = b.addLibrary(.{
        .name = "protobuf",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    lib_protobuf.root_module.linkLibrary(utf8_validity);
    lib_protobuf.root_module.addCSourceFiles(.{
        .files = lib_protobuf_src,
        .root = src.path("."),
        .flags = &.{},
        .language = .cpp,
    });
    lib_protobuf.root_module.addIncludePath(src.path("src"));
    lib_protobuf.root_module.addIncludePath(abseil.namedLazyPath("include"));
    lib_protobuf.root_module.linkLibrary(abseil.artifact("abseil"));

    const install_lib_protobuf = b.addInstallArtifact(lib_protobuf, .{});
    const install_lib_protobuf_step = b.step("install-lib-protobuf", "install lib protobuf");
    install_lib_protobuf_step.dependOn(&install_lib_protobuf.step);

    // lib upb
    const lib_upb_src = try getFiles(b, source_content, "# @//pkg:upb\n");
    const lib_upb = b.addLibrary(.{
        .name = "libupb",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    lib_upb.root_module.addCSourceFiles(.{
        .files = lib_upb_src,
        .root = src.path("."),
        .flags = &.{},
    });
    lib_upb.root_module.addCSourceFiles(.{
        .files = lib_upb_bootstrap,
        .flags = &.{},
        .root = src.path("."),
    });
    lib_upb.root_module.linkLibrary(utf8_validity);
    lib_upb.root_module.addIncludePath(src.path("src"));
    lib_upb.root_module.addIncludePath(src.path("upb/reflection/cmake/"));
    lib_upb.root_module.addIncludePath(src.path(""));
    lib_upb.root_module.addIncludePath(abseil.namedLazyPath("include"));

    const install_lib_upb = b.addInstallArtifact(lib_upb, .{});
    const install_lib_ubp_step = b.step("install-lib-upb", "install lib ubp");
    install_lib_ubp_step.dependOn(&install_lib_upb.step);

    // lib protoc
    const lib_protoc_src = try getFiles(b, source_content, "# @//pkg:protoc\n");
    const lib_protoc = b.addLibrary(.{
        .name = "protoc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    lib_protoc.root_module.addCSourceFiles(.{
        .files = lib_protoc_src,
        .root = src.path("."),
        .flags = &.{},
        .language = .cpp,
    });
    lib_protoc.root_module.linkLibrary(utf8_validity);
    lib_protoc.root_module.addIncludePath(src.path("src"));
    lib_protoc.root_module.addIncludePath(src.path(""));
    lib_protoc.root_module.addIncludePath(src.path("upb/reflection/cmake/"));
    lib_protoc.root_module.addIncludePath(abseil.namedLazyPath("include"));
    lib_protoc.root_module.linkLibrary(lib_protobuf);
    lib_protoc.root_module.linkLibrary(lib_upb);

    const install_lib_protoc = b.addInstallArtifact(lib_protoc, .{});
    const install_lib_protoc_step = b.step("install-lib-protoc", "install lib protoc");
    install_lib_protoc_step.dependOn(&install_lib_protoc.step);

    // protoc
    const protoc = b.addExecutable(.{
        .name = "protoc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    protoc.root_module.addCSourceFile(.{
        .file = src.path("src/google/protobuf/compiler/main.cc"),
        .flags = &.{},
        .language = .cpp,
    });
    protoc.root_module.addIncludePath(src.path(""));
    protoc.root_module.addIncludePath(src.path("src"));
    protoc.root_module.addIncludePath(abseil.namedLazyPath("include"));
    protoc.root_module.linkLibrary(lib_protoc);
    protoc.root_module.linkLibrary(utf8_validity);

    if (target.result.os.tag == .windows) {
        protoc.root_module.linkSystemLibrary("dbghelp", .{});
    }

    b.addNamedLazyPath("protobuf_source", src.path(""));
    b.installArtifact(protoc);
}

fn getFiles(b: *std.Build, file_lists: []const u8, block_tag: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;

    var lists = std.mem.splitSequence(u8, file_lists, block_tag);

    // Skip over start
    _ = lists.next();

    while (lists.next()) |block| {
        const end_of_block = std.mem.indexOf(u8, block, ")") orelse return error.EndOfBlockNotFound;
        const block_delimted = block[0..end_of_block];

        var lines = std.mem.splitScalar(u8, block_delimted, '\n');

        // Skip first
        _ = lines.next();

        while (lines.next()) |line| {
            if (line.len == 0) {
                continue;
            }

            const path = blk: {
                const src_dir_prefix = "${protobuf_SOURCE_DIR}/";
                if (std.mem.find(u8, line, src_dir_prefix)) |offset| {
                    break :blk line[offset + src_dir_prefix.len ..];
                }

                std.log.err("unknown line {s}", .{line});
                return error.PrefixNotFound;
            };

            if (std.mem.endsWith(u8, path, ".inc")) {
                continue;
            }
            if (std.mem.endsWith(u8, path, ".h")) {
                continue;
            }
            try items.append(b.allocator, path);
        }
    }

    return items.toOwnedSlice(b.allocator);
}

const lib_upb_bootstrap: []const []const u8 = &.{
    "upb/reflection/cmake/google/protobuf/descriptor.upb.h",
    "upb/reflection/cmake/google/protobuf/descriptor.upb_minitable.h",
    "upb/reflection/cmake/google/protobuf/descriptor.upb_minitable.c",
    "upb/reflection/cmake/google/protobuf/json_enumvalue_options.upb.h",
    "upb/reflection/cmake/google/protobuf/json_enumvalue_options.upb_minitable.h",
    "upb/reflection/cmake/google/protobuf/json_enumvalue_options.upb_minitable.c",
};
