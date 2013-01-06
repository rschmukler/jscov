fs = require 'fs'
path = require 'path'
_ = require 'underscore'
esprima = require 'esprima'
escodegen = require 'escodegen'
wrench = require 'wrench'
coffee = require 'coffee-script'

reservedWords = [
  'break'
  'case'
  'catch'
  'continue'
  'debugger'
  'default'
  'delete'
  'do'
  'else'
  'finally'
  'for'
  'function'
  'if'
  'in'
  'instanceof'
  'new'
  'return'
  'switch'
  'this'
  'throw'
  'try'
  'typeof'
  'var'
  'void'
  'while'
  'with'
]

isValidIdentifier = (name) ->
  name? && (name.toString().match(/^[_a-zA-Z][_a-zA-Z0-9]*$/) || name.toString().match(/^[1-9][0-9]*$/)) && reservedWords.indexOf(name) == -1

exports.rewriteSource = (code, filename) ->

  injectList = []

  inject = (x) ->
    injectList.push(x.loc.start.line)

    type: 'ExpressionStatement'
    expression:
      type: 'UpdateExpression'
      operator: '++'
      prefix: false
      argument:
        type: 'MemberExpression'
        computed: true
        property:
          type: 'Literal'
          value: x.loc.start.line
        object:
          type: 'MemberExpression'
          computed: true
          object:
            type: 'Identifier'
            name: '_$jscoverage'
          property:
            type: 'Literal'
            value: filename

  ast = esprima.parse(code, { loc: true })

  escodegen.traverse ast,
    enter: (node) ->
      if node.type == 'MemberExpression' && node.computed && node.property && node.property.type == 'Literal' && isValidIdentifier(node.property.value)
        if node.property.value.toString().match(/^[1-9][0-9]*$/)
          node.property = { type: 'Literal', value: parseInt(node.property.value, 10) }
        else
          node.computed = false
          node.property = { type: 'Identifier', name: node.property.value }
      if ['BlockStatement', 'Program'].indexOf(node.type) != -1
        node.body = _.flatten node.body.map (x) -> [inject(x), x]
      if node.type == 'SwitchCase'
        node.consequent = _.flatten node.consequent.map (x) -> [inject(x), x]
      if node.type == 'IfStatement'
        ['consequent', 'alternate'].forEach (src) ->
          if node[src]? && node[src].type != 'BlockStatement'
            node[src] =
              type: 'BlockStatement'
              body: [node[src]]
      if ['ForInStatement', 'ForStatement', 'WhileStatement', 'WithStatement', 'DoWhileStatement'].indexOf(node.type) != -1 && node.body? && node.body.type != 'BlockStatement'
        node.body =
          type: 'BlockStatement'
          body: [node.body]

  trackedLines = _.sortBy(_.unique(injectList), _.identity)

  sourceMappings = [
    (x) -> x.replace(/&/g, '&amp;')
    (x) -> x.replace(/</g, '&lt;')
    (x) -> x.replace(/>/g, '&gt;')
    (x) -> x.replace(/"/g, '\\"')
    (x) -> '"' + x + '"'
  ]

  originalSource = code.split('\n').map (line) -> sourceMappings.reduce(((src, f) -> f(src)), line)
  originalSource = originalSource.slice(0, -1) if _.last(originalSource) == '""' # useless trimming - just to keep the semantics the same as for jscoverage

  output = []
  output.push "/* automatically generated by jscov - do not edit */"
  output.push "if (typeof _$jscoverage === 'undefined') _$jscoverage = {};"
  output.push "if (! _$jscoverage['#{filename}']) {"
  output.push "  _$jscoverage['#{filename}'] = [];"
  trackedLines.forEach (line) ->
    output.push "  _$jscoverage['#{filename}'][#{line}] = 0;"
  output.push "}"
  output.push escodegen.generate(ast, { indent: "  " })
  output.push "_$jscoverage['#{filename}'].source = [" + originalSource.join(",") + "];"

  output.join('\n')


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
