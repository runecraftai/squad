const filesystemPlugin = /^(?:@tanstack\/router-plugin(?:\/.*)?|@tanstack\/router-vite-plugin)$/;
const generatedRouteTree = /(?:^|\/)routeTree(?:\.gen)?(?:\.[cm]?[jt]sx?)?$/i;

const rule = {
  meta: {
    type: "problem",
    docs: {
      description: "require code-based TanStack Router trees instead of filesystem routes",
    },
    messages: {
      fileRoute: "Use createRoute in the code-based route tree; createFileRoute is not allowed.",
      filesystemPlugin: "Use the code-based route tree; the TanStack filesystem-route plugin is not allowed.",
      generatedTree: "Import the code-based route tree; generated routeTree modules are not allowed.",
    },
    schema: [],
  },
  create(context) {
    return {
      CallExpression(node) {
        if (node.callee.type === "Identifier" && node.callee.name === "createFileRoute") {
          context.report({ node, messageId: "fileRoute" });
        }
      },
      ImportDeclaration(node) {
        const source = node.source.value;
        if (typeof source !== "string") return;
        if (filesystemPlugin.test(source)) {
          context.report({ node, messageId: "filesystemPlugin" });
        } else if (generatedRouteTree.test(source)) {
          context.report({ node, messageId: "generatedTree" });
        }
      },
    };
  },
};

export default {
  meta: { name: "squad", version: "1.0.0" },
  rules: { "no-filesystem-routes": rule },
};
