fs = require 'fs'
path = require 'path'
_ = require 'underscore'
esprima = require 'esprima'
escodegen = require 'escodegen'
wrench = require 'wrench'
coffee = require 'coffee-script'
tools = require './tools'
estools = require './estools'


coverageVar = '_$jscoverage'









formatTree = (ast) ->
  # formatting (no difference in result, just here to give it exactly the same semantics as JSCoverage)
  # this block should be part of the comparisons in the tests; not the source
  format = true

  while format
    format = false
    escodegen.traverse ast,
      enter: (node) ->
        if ['property', 'argument', 'test'].some((prop) -> node[prop]?.type == 'Literal')
          if node.type == 'MemberExpression' && node.computed && tools.isValidIdentifier(node.property.value)
            node.computed = false
            node.property = { type: 'Identifier', name: node.property.value }
          else if node.type == 'MemberExpression' && node.computed && node.property.value?.toString().match(/^[1-9][0-9]*$/)
            node.property = estools.createLiteral(parseInt(node.property.value, 10))
          else if node.type == 'UnaryExpression'
            if node.operator == '!'
              estools.replaceWithLiteral(node, !node.argument.value)
              format = true
            if node.operator == "~" && typeof node.argument.value == 'number'
              estools.replaceWithLiteral(node, ~node.argument.value)
              format = true
          else if node.type == 'ConditionalExpression'
            if typeof node.test.value == 'string' || typeof node.test.value == 'number' || typeof node.test.value == 'boolean'
              if node.test.value
                tools.replaceProperties(node, node.consequent)
              else
                tools.replaceProperties(node, node.alternate)
          else if node.type == 'WhileStatement' # this should probably go for other types of loops as well
            node.test.value = !!node.test.value
        else
          if node.type == 'MemberExpression' && !node.computed && node.property.type == 'Identifier' && tools.isReservedWord(node.property.name)
            node.computed = true
            node.property = estools.createLiteral(node.property.name)
          else if node.type == 'BinaryExpression' && node.left.type == 'Literal' && node.right.type == 'Literal' && typeof node.left.value == 'string' && typeof node.right.value == 'string' && node.operator == '+'
            estools.replaceWithLiteral(node, node.left.value + node.right.value)
            format = true
          else if node.type == 'BinaryExpression' && estools.mathable(node.left) && estools.mathable(node.right)
            lv = estools.getVal(node.left)
            rv = estools.getVal(node.right)
            if typeof lv == 'number' && typeof rv == 'number' && node.operator in ['+', '-', '*', '%', '/', '<<', '>>', '>>>']
              binval = tools.evalBinaryExpression(lv, node.operator, rv)
              estools.replaceWithLiteral(node, binval)
              format = true

  estools.replaceNegativeInfinities(ast)
  estools.replacePositiveInfinities(ast)







writeFile = do ->
  sourceMappings = [
    (x) -> x.replace(/&/g, '&amp;')
    (x) -> x.replace(/</g, '&lt;')
    (x) -> x.replace(/>/g, '&gt;')
    (x) -> x.replace(/\\/g, '\\\\')
    (x) -> x.replace(/"/g, '\\"')
    (x) -> tools.strToNumericEntity(x)
    (x) -> '"' + x + '"'
  ]

  (originalCode, coveredCode, filename, trackedLines) ->

    originalSource = originalCode.split(/\r?\n/g).map (line) -> sourceMappings.reduce(((src, f) -> f(src)), line)

    # useless trimming - just to keep the semantics the same as for jscoverage
    originalSource = originalSource.slice(0, -1) if _.last(originalSource) == '""'

    output = []
    output.push "/* automatically generated by jscov - do not edit */"
    output.push "if (typeof #{coverageVar} === 'undefined') #{coverageVar} = {};"
    output.push "if (!#{coverageVar}['#{filename}']) {"
    output.push "  #{coverageVar}['#{filename}'] = [];"
    trackedLines.forEach (line) ->
      output.push "  #{coverageVar}['#{filename}'][#{line}] = 0;"
    output.push "}"
    output.push coveredCode
    output.push "#{coverageVar}['#{filename}'].source = [" + originalSource.join(",") + "];"

    output.join('\n') # should maybe windows style line-endings be used here in some cases?


exports.rewriteSource = (code, filename) ->

  injectList = []

  ast = esprima.parse(code, { loc: true })

  formatTree(ast)

  # all optional blocks should be actual blocks (in order to make it possible to put coverage information in them)
  escodegen.traverse ast,
    enter: (node) ->
      if node.type == 'IfStatement'
        ['consequent', 'alternate'].forEach (src) ->
          if node[src]? && node[src].type != 'BlockStatement'
            node[src] =
              type: 'BlockStatement'
              body: [node[src]]
      if node.type in ['ForInStatement', 'ForStatement', 'WhileStatement', 'WithStatement', 'DoWhileStatement'] && node.body? && node.body.type != 'BlockStatement'
        node.body =
          type: 'BlockStatement'
          body: [node.body]

  # Remove extra empty statements trailing returns without semicolons (no semantic difference, just to keep in line with JSCoverage)
  # Also, remove dead code (no semantic difference - JSCovergage, are you happy now?)
  escodegen.traverse ast,
    enter: (node) ->
      if node.type in ['BlockStatement', 'Program']
        node.body = node.body.filter (x, i) ->
          !(x.type == 'EmptyStatement' && i-1 >= 0 && node.body[i-1].type in ['ReturnStatement', 'VariableDeclaration', 'ExpressionStatement'] && node.body[i-1].loc.end.line == x.loc.start.line) &&
          !(x.type == 'IfStatement' && x.test.type == 'Literal' && !x.test.value) # this should probably go for all the loops as well. write tests to prove/disprove it.

  # insert the coverage information
  escodegen.traverse ast,
    enter: (node) ->
      if node.type in ['BlockStatement', 'Program']
        node.body = _.flatten node.body.map (x) ->
          if x.expression?.type == 'FunctionExpression'
            injectList.push(x.expression.loc.start.line)
            [estools.coverageNode(x.expression, filename, coverageVar), x]
          else if x.expression?.type == 'CallExpression'
            injectList.push(x.expression.loc.start.line)
            [estools.coverageNode(x.expression, filename, coverageVar), x]
          else if x.type == 'FunctionDeclaration'
            injectList.push(x.body.loc.start.line)
            [estools.coverageNode(x.body, filename, coverageVar), x]
          else
            injectList.push(x.loc.start.line)
            [estools.coverageNode(x, filename, coverageVar), x]
      if node.type == 'SwitchCase'
        node.consequent = _.flatten node.consequent.map (x) ->
          injectList.push(x.loc.start.line)
          [estools.coverageNode(x, filename, coverageVar), x]

  # wrap it up
  trackedLines = _.sortBy(_.unique(injectList), _.identity)
  outcode = escodegen.generate(ast, { indent: "  " })
  writeFile(code, outcode, filename, trackedLines)


exports.rewriteFolder = (source, target, options, callback) ->
  try
    if !callback?
      callback = options
      options = {}

    wrench.rmdirSyncRecursive(target, true)

    wrench.readdirSyncRecursive(source).forEach (file) ->
      fullpath = path.join(source, file)
      return if fs.lstatSync(fullpath).isDirectory()

      data = fs.readFileSync(fullpath, 'utf8')

      if file.match(/\.coffee$/)
        data = coffee.compile(data)
      else if !file.match(/\.js$/)
        data = null

      if data != null
        output = exports.rewriteSource(data, file)
        outfile = path.join(target, file).replace(/\.coffee$/, '.js')
        wrench.mkdirSyncRecursive(path.dirname(outfile))
        fs.writeFileSync(outfile, output, 'utf8')

  catch ex
    callback(ex)
    return

  callback(null)
