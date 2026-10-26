const routerPackage = "@tanstack/react-router";
const filesystemPlugin =
  /^@tanstack\/(?:router-plugin(?:\/.*)?|router-vite-plugin|router-cli(?:\/.*)?|router-generator(?:\/.*)?|fs-routes(?:\/.*)?)$/;
const generatedRouteTree = /(?:^|\/)routeTree\.gen(?:\.[cm]?[jt]sx?)?$/i;

function literalValue(node) {
  if (!node) return null;
  if (node.type === "Literal" && typeof node.value === "string") return node.value;
  if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
    return node.quasis[0]?.value?.cooked ?? null;
  }
  return null;
}

function requireSource(node) {
  if (!node || node.type !== "CallExpression" || node.arguments.length !== 1) return null;
  if (node.callee.type !== "Identifier" || node.callee.name !== "require") return null;
  return literalValue(node.arguments[0]);
}

function moduleSource(node) {
  if (!node) return null;
  if (node.type === "AwaitExpression") return moduleSource(node.argument);
  if (!node || node.type !== "CallExpression" || node.arguments.length !== 1) return null;
  if (node.callee.type === "Import") return literalValue(node.arguments[0]);
  return requireSource(node);
}

function memberName(node) {
  if (!node || node.type !== "MemberExpression") return null;
  if (!node.computed) return node.property.type === "Identifier" ? node.property.name : null;
  return literalValue(node.property);
}

function importSource(node) {
  if (!node.source) return null;
  return literalValue(node.source);
}

function propertyKeyName(node) {
  if (!node || node.type !== "Property") return null;
  if (!node.computed) return node.key.type === "Identifier" ? node.key.name : null;
  return literalValue(node.key);
}

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
    const fileRouteBindings = new Set(["createFileRoute"]);

    function reportSource(node, source) {
      if (typeof source !== "string") return;
      const path = source.split(/[?#]/)[0];
      if (filesystemPlugin.test(path)) {
        context.report({ node, messageId: "filesystemPlugin" });
      } else if (generatedRouteTree.test(path)) {
        context.report({ node, messageId: "generatedTree" });
      }
    }

    function recordImport(node) {
      if (importSource(node) !== routerPackage) return;
      for (const specifier of node.specifiers ?? []) {
        if (specifier.type !== "ImportSpecifier") continue;
        const imported = specifier.imported;
        const name = imported.type === "Identifier" ? imported.name : literalValue(imported);
        if (name === "createFileRoute") fileRouteBindings.add(specifier.local.name);
      }
    }

    function recordRequireDestructuring(node) {
      if (requireSource(node) !== routerPackage) return;
      let parent = node.parent;
      while (parent && parent.type === "AwaitExpression") parent = parent.parent;
      if (!parent || parent.type !== "VariableDeclarator") return;
      if (!parent.id || parent.id.type !== "ObjectPattern") return;
      for (const property of parent.id.properties ?? []) {
        if (propertyKeyName(property) !== "createFileRoute") continue;
        if (property.value?.type !== "Identifier") continue;
        fileRouteBindings.add(property.value.name);
      }
    }

    return {
      ImportDeclaration(node) {
        recordImport(node);
        reportSource(node, importSource(node));
      },
      ExportNamedDeclaration(node) {
        reportSource(node, importSource(node));
      },
      ExportAllDeclaration(node) {
        reportSource(node, importSource(node));
      },
      CallExpression(node) {
        const name = memberName(node.callee);
        if (name === "createFileRoute") {
          context.report({ node, messageId: "fileRoute" });
        } else if (node.callee.type === "Identifier" && fileRouteBindings.has(node.callee.name)) {
          context.report({ node, messageId: "fileRoute" });
        }
        recordRequireDestructuring(node);
        reportSource(node, moduleSource(node));
      },
      ImportExpression(node) {
        reportSource(node, literalValue(node.source));
      },
    };
  },
};

export default {
  meta: { name: "squad", version: "1.0.0" },
  rules: { "no-filesystem-routes": rule },
};
