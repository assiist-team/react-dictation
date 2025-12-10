// Babel plugin to strip TypeScript 'as' type assertions
module.exports = function() {
  return {
    visitor: {
      TSTypeAssertion(path) {
        path.replaceWith(path.node.expression);
      },
      TSAsExpression(path) {
        path.replaceWith(path.node.expression);
      },
    },
  };
};
