Range = {}

# Public: Determines the type of Range of the provided object and returns
# a suitable Range instance.
#
# r - A range Object.
#
# Examples
#
#   selection = window.getSelection()
#   Range.sniff(selection.getRangeAt(0))
#   # => Returns a BrowserRange instance.
#
# Returns a Range object or false.
Range.sniff = (r) ->
  if r.commonAncestorContainer?
    new Range.BrowserRange(r)
  else if typeof r.startContainer is "string"
    new Range.SerializedRange(r)
  else if typeof r.start is "string"
    new Range.SerializedRange
      startContainer: r.start
      startOffset: r.startOffset
      endContainer: r.end
      endOffset: r.endOffset
  else if r.start and typeof r.start is "object"
    new Range.NormalizedRange(r)
  else
    console.error(_t("Could not sniff range type"))
    false

# Public: Finds an Element Node using an XPath relative to the document root.
#
# If the document is served as application/xhtml+xml it will try and resolve
# any namespaces within the XPath.
#
# xpath - An XPath String to query.
#
# Examples
#
#   node = Range.nodeFromXPath('/html/body/div/p[2]')
#   if node
#     # Do something with the node.
#
# Returns the Node if found otherwise null.
Range.nodeFromXPath = (xpath, root=document) ->
  evaluateXPath = (xp, nsResolver=null) ->
    try
      document.evaluate('.' + xp, root, nsResolver, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue
    catch exception
      # There are cases when the evaluation fails, because the
      # HTML documents contains nodes with invalid names,
      # for example tags with equal signs in them, or something like that.
      # In these cases, the XPath expressions will have these abominations,
      # too, and then they can not be evaluated.
      # In these cases, we get an XPathException, with error code 52.
      # See http://www.w3.org/TR/DOM-Level-3-XPath/xpath.html#XPathException
      # This does not necessarily make any sense, but this what we see
      # happening.
      console.log "XPath evaluation failed."
      console.log "Trying fallback..."
      # We have a an 'evaluator' for the really simple expressions that
      # should work for the simple expressions we generate.
      Util.nodeFromXPath(xp, root)

  if not $.isXMLDoc document.documentElement
    evaluateXPath xpath
  else
    # We're in an XML document, create a namespace resolver function to try
    # and resolve any namespaces in the current document.
    # https://developer.mozilla.org/en/DOM/document.createNSResolver
    customResolver = document.createNSResolver(
      if document.ownerDocument == null
        document.documentElement
      else
        document.ownerDocument.documentElement
    )
    node = evaluateXPath xpath, customResolver

    unless node
      # If the previous search failed to find a node then we must try to
      # provide a custom namespace resolver to take into account the default
      # namespace. We also prefix all node names with a custom xhtml namespace
      # eg. 'div' => 'xhtml:div'.
      xpath = (for segment in xpath.split '/'
        if segment and segment.indexOf(':') == -1
          segment.replace(/^([a-z]+)/, 'xhtml:$1')
        else segment
      ).join('/')

      # Find the default document namespace.
      namespace = document.lookupNamespaceURI null

      # Try and resolve the namespace, first seeing if it is an xhtml node
      # otherwise check the head attributes.
      customResolver  = (ns) ->
        if ns == 'xhtml' then namespace
        else document.documentElement.getAttribute('xmlns:' + ns)

      node = evaluateXPath xpath, customResolver
    node

class Range.RangeError extends Error
  constructor: (@type, @message, @parent=null) ->
    super(@message)

# Public: Creates a wrapper around a range object obtained from a DOMSelection.
class Range.BrowserRange

  # Public: Creates an instance of BrowserRange.
  #
  # object - A range object obtained via DOMSelection#getRangeAt().
  #
  # Examples
  #
  #   selection = window.getSelection()
  #   range = new Range.BrowserRange(selection.getRangeAt(0))
  #
  # Returns an instance of BrowserRange.
  constructor: (obj) ->
    @commonAncestorContainer = obj.commonAncestorContainer
    @startContainer          = obj.startContainer
    @startOffset             = obj.startOffset
    @endContainer            = obj.endContainer
    @endOffset               = obj.endOffset

  # Public: normalize works around the fact that browsers don't generate
  # ranges/selections in a consistent manner. Some (Safari) will create
  # ranges that have (say) a textNode startContainer and elementNode
  # endContainer. Others (Firefox) seem to only ever generate
  # textNode/textNode or elementNode/elementNode pairs.
  #
  # Returns an instance of Range.NormalizedRange
  normalize: (root) ->
    if @tainted
      console.error(_t("You may only call normalize() once on a BrowserRange!"))
      return false
    else
      @tainted = true

    r = {}

    for p in ['start', 'end']
      node = this[p + 'Container']
      offset = this[p + 'Offset']

      if node.nodeType is Node.ELEMENT_NODE
        # Get specified node.
        it = node.childNodes[offset]
        # If it doesn't exist, that means we need the end of the
        # previous one.
        node = it or node.childNodes[offset - 1]

        # Is this an IMG?
        isImg = node.nodeType is Node.ELEMENT_NODE and node.tagName.toLowerCase() is "img"
        if isImg
          # This is an img. Don't do anything.
          offset = 0
        else
          # if node doesn't have any children, it's a <br> or <hr> or
          # other self-closing tag, and we actually want the textNode
          # that ends just before it
          while node.nodeType is Node.ELEMENT_NODE and not node.firstChild and not isImg
            it = null # null out ref to node so offset is correctly calculated below.
            node = node.previousSibling

          # Try to find a text child
          while (node.nodeType isnt Node.TEXT_NODE)
            node = node.firstChild

          offset = if it then 0 else node.nodeValue.length

      r[p] = node
      r[p + 'Offset'] = offset
      r[p + 'Img'] = isImg

    # We have collected the initial data.

    # Now let's start to slice & dice the text elements!
    nr = {}
    changed = false

    if r.startOffset > 0
      # Do we really have to cut?
      if r.start.data.length > r.startOffset
        # Yes. Cut.
        nr.start = r.start.splitText(r.startOffset)
        changed = true
      else
        # Avoid splitting off zero-length pieces.
        nr.start = r.start.nextSibling
    else
      nr.start = r.start

    # is the whole selection inside one text element ?
    if r.start is r.end and not r.startImg
      if nr.start.nodeValue.length > (r.endOffset - r.startOffset)
        nr.start.splitText(r.endOffset - r.startOffset)
        changed = true
      nr.end = nr.start
    else # no, the end of the selection is in a separate text element
      # does the end need to be cut?
      if r.end.nodeValue.length > r.endOffset and not r.endImg
        r.end.splitText(r.endOffset)
        changed = true
      nr.end = r.end

    # Make sure the common ancestor is an element node.
    nr.commonAncestor = @commonAncestorContainer
    while nr.commonAncestor.nodeType isnt Node.ELEMENT_NODE
      nr.commonAncestor = nr.commonAncestor.parentNode

    if window.DomTextMapper? and changed
      window.DomTextMapper.changed nr.commonAncestor, "range normalization"

    new Range.NormalizedRange(nr)

  # Public: Creates a range suitable for storage.
  #
  # root           - A root Element from which to anchor the serialisation.
  # ignoreSelector - A selector String of elements to ignore. For example
  #                  elements injected by the annotator.
  #
  # Returns an instance of SerializedRange.
  serialize: (root, ignoreSelector) ->
    this.normalize(root).serialize(root, ignoreSelector)

# Public: A normalised range is most commonly used throughout the annotator.
# its the result of a deserialised SerializedRange or a BrowserRange with
# out browser inconsistencies.
class Range.NormalizedRange

  # Public: Creates an instance of a NormalizedRange.
  #
  # This is usually created by calling the .normalize() method on one of the
  # other Range classes rather than manually.
  #
  # obj - An Object literal. Should have the following properties.
  #       commonAncestor: A Element that encompasses both the start and end nodes
  #       start:          The first TextNode in the range.
  #       end             The last TextNode in the range.
  #
  # Returns an instance of NormalizedRange.
  constructor: (obj) ->
    @commonAncestor = obj.commonAncestor
    @start          = obj.start
    @end            = obj.end

  # Public: For API consistency.
  #
  # Returns itself.
  normalize: (root) ->
    this

  # Public: Limits the nodes within the NormalizedRange to those contained
  # withing the bounds parameter. It returns an updated range with all
  # properties updated. NOTE: Method returns null if all nodes fall outside
  # of the bounds.
  #
  # bounds - An Element to limit the range to.
  #
  # Returns updated self or null.
  limit: (bounds) ->
    nodes = $.grep this.textNodes(), (node) ->
      node.parentNode == bounds or $.contains(bounds, node.parentNode)

    return null unless nodes.length

    @start = nodes[0]
    @end   = nodes[nodes.length - 1]

    startParents = $(@start).parents()
    for parent in $(@end).parents()
      if startParents.index(parent) != -1
        @commonAncestor = parent
        break
    this

  # Convert this range into an object consisting of two pairs of (xpath,
  # character offset), which can be easily stored in a database.
  #
  # root -           The root Element relative to which XPaths should be calculated
  # ignoreSelector - A selector String of elements to ignore. For example
  #                  elements injected by the annotator.
  #
  # Returns an instance of SerializedRange.
  serialize: (root, ignoreSelector) ->

    serialization = (node, isEnd) ->
      if ignoreSelector
        origParent = $(node).parents(":not(#{ignoreSelector})").eq(0)
      else
        origParent = $(node).parent()

      xpath = Util.xpathFromNode(origParent, root)[0]
      textNodes = Util.getTextNodes(origParent)

      # Calculate real offset as the combined length of all the
      # preceding textNode siblings. We include the length of the
      # node if it's the end node.
      nodes = textNodes.slice(0, textNodes.index(node))
      offset = 0
      for n in nodes
        offset += n.nodeValue.length

      isImg = node.nodeType is Node.ELEMENT_NODE and node.tagName.toLowerCase() is "img"

      if isEnd and not isImg then [xpath, offset + node.nodeValue.length] else [xpath, offset]

    start = serialization(@start)
    end   = serialization(@end, true)

    new Range.SerializedRange({
      # XPath strings
      start: start[0]
      end: end[0]
      # Character offsets (integer)
      startOffset: start[1]
      endOffset: end[1]
    })

  # Public: Creates a concatenated String of the contents of all the text nodes
  # within the range.
  #
  # Returns a String.
  text: ->
    (for node in this.textNodes()
      node.nodeValue
    ).join ''

  # Public: Fetches only the text nodes within th range.
  #
  # Returns an Array of TextNode instances.
  textNodes: ->
    textNodes = Util.getTextNodes($(this.commonAncestor))
    [start, end] = [textNodes.index(this.start), textNodes.index(this.end)]
    # Return the textNodes that fall between the start and end indexes.
    $.makeArray textNodes[start..end]

  # Public: Converts the Normalized range to a native browser range.
  #
  # See: https://developer.mozilla.org/en/DOM/range
  #
  # Examples
  #
  #   selection = window.getSelection()
  #   selection.removeAllRanges()
  #   selection.addRange(normedRange.toRange())
  #
  # Returns a Range object.
  toRange: ->
    range = document.createRange()
    range.setStartBefore(@start)
    range.setEndAfter(@end)
    range

# Public: A range suitable for storing in local storage or serializing to JSON.
class Range.SerializedRange

  # Public: Creates a SerializedRange
  #
  # obj - The stored object. It should have the following properties.
  #       start:       An xpath to the Element containing the first TextNode
  #                    relative to the root Element.
  #       startOffset: The offset to the start of the selection from obj.start.
  #       end:         An xpath to the Element containing the last TextNode
  #                    relative to the root Element.
  #       startOffset: The offset to the end of the selection from obj.end.
  #
  # Returns an instance of SerializedRange
  constructor: (obj) ->
    @start       = obj.start
    @startOffset = obj.startOffset
    @end         = obj.end
    @endOffset   = obj.endOffset

  # Public: Creates a NormalizedRange.
  #
  # root - The root Element from which the XPaths were generated.
  #
  # Returns a NormalizedRange instance.
  normalize: (root) ->
    range = {}

    for p in ['start', 'end']
      try
        node = Range.nodeFromXPath(this[p], root)
      catch e
        throw new Range.RangeError(p, "Error while finding #{p} node: #{this[p]}: " + e, e)

      if not node
        throw new Range.RangeError(p, "Couldn't find #{p} node: #{this[p]}")

      # Unfortunately, we *can't* guarantee only one textNode per
      # elementNode, so we have to walk along the element's textNodes until
      # the combined length of the textNodes to that point exceeds or
      # matches the value of the offset.
      length = 0
      targetOffset = this[p + 'Offset'] + (if p is "start" then 1 else 0)
      for tn in Util.getTextNodes($(node))
        if (length + tn.nodeValue.length >= targetOffset)
          range[p + 'Container'] = tn
          range[p + 'Offset'] = this[p + 'Offset'] - length
          break
        else
          length += tn.nodeValue.length

      # If we fall off the end of the for loop without having set
      # 'startOffset'/'endOffset', the element has shorter content than when
      # we annotated, so throw an error:
      if not range[p + 'Offset']?
        throw new Range.RangeError("#{p}offset", "Couldn't find offset #{this[p + 'Offset']} in element #{this[p]}")

    # Here's an elegant next step...
    #
    #   range.commonAncestorContainer = $(range.startContainer).parents().has(range.endContainer)[0]
    #
    # ...but unfortunately Node.contains() is broken in Safari 5.1.5 (7534.55.3)
    # and presumably other earlier versions of WebKit. In particular, in a
    # document like
    #
    #   <p>Hello</p>
    #
    # the code
    #
    #   p = document.getElementsByTagName('p')[0]
    #   p.contains(p.firstChild)
    #
    # returns `false`. Yay.
    #
    # So instead, we step through the parents from the bottom up and use
    # Node.compareDocumentPosition() to decide when to set the
    # commonAncestorContainer and bail out.

    contains = if not document.compareDocumentPosition?
                 # IE
                 (a, b) -> a.contains(b)
               else
                 # Everyone else
                 (a, b) -> a.compareDocumentPosition(b) & 16

    $(range.startContainer).parents().each ->
      if contains(this, range.endContainer)
        range.commonAncestorContainer = this
        return false

    new Range.BrowserRange(range).normalize(root)

  # Public: Creates a range suitable for storage.
  #
  # root           - A root Element from which to anchor the serialisation.
  # ignoreSelector - A selector String of elements to ignore. For example
  #                  elements injected by the annotator.
  #
  # Returns an instance of SerializedRange.
  serialize: (root, ignoreSelector) ->
    this.normalize(root).serialize(root, ignoreSelector)

  # Public: Returns the range as an Object literal.
  toObject: ->
    {
      start: @start
      startOffset: @startOffset
      end: @end
      endOffset: @endOffset
    }
