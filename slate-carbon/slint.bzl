"""Bazel rule for generating C++ headers from Slint UI definition files using slint-compiler."""

def _slint_compile_impl(ctx):
    out_h = ctx.actions.declare_file(ctx.attr.output_header)
    include_args = []
    for inc in ctx.files.include_dirs:
        include_args.extend(["-I", inc.path])

    inputs = ctx.files.srcs + ctx.files.include_dirs

    ctx.actions.run(
        outputs = [out_h],
        inputs = inputs,
        executable = ctx.executable._compiler,
        arguments = [
            "--style", ctx.attr.style,
            "-o", out_h.path,
        ] + include_args + [ctx.file.entry.path],
        mnemonic = "SlintCompile",
        progress_message = "Compiling Slint UI file %s to C++" % ctx.file.entry.short_path,
    )

    return [
        DefaultInfo(files = depset([out_h])),
        CcInfo(
            compilation_context = cc_common.create_compilation_context(
                headers = depset([out_h]),
                includes = depset([out_h.dirname]),
            ),
        ),
    ]

slint_compile = rule(
    implementation = _slint_compile_impl,
    attrs = {
        "entry": attr.label(
            mandatory = True,
            allow_single_file = [".slint"],
            doc = "Primary .slint entry file",
        ),
        "srcs": attr.label_list(
            allow_files = [".slint", ".png", ".svg"],
            doc = "Supporting Slint files, layouts, and assets",
        ),
        "include_dirs": attr.label_list(
            allow_files = True,
            doc = "Include directories for Slint imports",
        ),
        "style": attr.string(
            default = "fluent",
            doc = "Slint widget style to apply",
        ),
        "output_header": attr.string(
            mandatory = True,
            doc = "Name of generated C++ header file (e.g. slate_ui.h)",
        ),
        "_compiler": attr.label(
            default = Label("//toolchain:slint_compiler"),
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Compiles .slint markup into C++ header code using slint-compiler",
)
