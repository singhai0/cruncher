window.Cruncher = Cr = window.Cruncher || {}

$ ->
    Cr.editor = editor = null
    Cr.editor = editor = CodeMirror.fromTextArea $('#code')[0],
        lineNumbers: true
        lineWrapping: true,
        gutters: ['lineState']
        theme: 'cruncher'

    Cr.getFreeMarkedSpans = (line) ->
        handle = editor.getLineHandle line
        if handle.markedSpans?
            return (span for span in handle.markedSpans \
                when span.marker.className == 'free-number')
        else
            return []
    
    parsedLines = []
    reparseLine = (line) ->
        text = editor.getLine line
       
        textToParse = text
        markedPieces = []

        freeMarkedSpans = Cr.getFreeMarkedSpans line
        # FIXME work for > 1 mark
        if freeMarkedSpans?[0]
            freeMark = freeMarkedSpans[0]

            markedPieces.push (text.substring 0, freeMark.from)
            markedPieces.push (text.substring freeMark.to, text.length)

            freePlaceholder = (Array freeMark.to - freeMark.from + 1).join ''

            textToParse = markedPieces.join freePlaceholder # horrifying hack

        console.log 'parsing', textToParse            
        try
            parsedLines[line] = parser.parse textToParse

            Cr.unsetLineState line, 'parseError'
            
        catch e
            console.log 'parse error on line', line
            
            parsedLines[line] = null

            Cr.setLineState line, 'parseError'

    fixCursor = (oldCursor) ->
        # runs while evaluating and constraining a line
        # returns weakened version of onChange handler that just makes sure
        # user's cursor stays in a sane position while we evalLine

        return (instance, changeObj) ->
            return unless oldCursor.line == changeObj.to.line

            if oldCursor.ch > changeObj.from.ch
                cursorOffset = changeObj.text[0].length - (changeObj.to.ch - changeObj.from.ch)
                editor.setCursor
                    line: oldCursor.line
                    ch: oldCursor.ch + cursorOffset

                # TODO put this somewhere else so drag logic isn't mixed with eval logic
                if draggingState?
                    draggingState.from.ch += cursorOffset
                    draggingState.to.ch += cursorOffset
            else
                editor.setCursor oldCursor
            
            console.log 'editing', oldCursor, changeObj

    evalLine = (line) ->
        # runs after a line changes
        # (except, of course, when evalLine is the changer)
        # reconstrain the free variable(s) [currently only 1 is supported]
        # so that the equation is true,
        # or make the line an equation

        reparseLine line

        Cr.unsetLineState line, stateName for stateName in \
            ['overDetermined', 'underDetermined']
        
        editor.off 'change', onChange
        fixOnChange = fixCursor editor.getCursor()
        editor.on 'change', fixOnChange

        text = editor.getLine line
        parsed = parsedLines[line]
        if parsed?.constructor == Cr.Expression # edited a line without another side (yet)
            freeString = parsed.toString()

            from =
                line: line
                ch: text.length + ' = '.length
            to =
                line: line
                ch: text.length + ' = '.length + freeString.length

            editor.replaceRange ' = ' + freeString, from, from

            editor.markText from, to, { className: 'free-number' }

            reparseLine line
            
        else if parsed?.constructor == Cr.Equation
            freeMarkedSpans = Cr.getFreeMarkedSpans line
            
            # search for free variables that we can change to keep the equality constraint
            if freeMarkedSpans?.length < 1
                Cr.setLineState line, 'overDetermined'
                console.log 'This equation cannot be solved! Not enough freedom'

            else if freeMarkedSpans?.length == 1
                console.log 'Solvable if you constrain', freeMarkedSpans
                [leftF, rightF] = for val in [parsed.left, parsed.right]
                    do (val) -> if typeof val.num == 'function' then val.num else (x) -> val.num

                try
                    window.leftF = leftF; window.rightF = rightF
                    solution = (numeric.uncmin ((x) -> (Math.pow (leftF x[0]) - (rightF x[0]), 2)), [1]).solution[0]
                    solutionText = solution.toFixed 2
                    console.log 'st', solutionText

                    editor.replaceRange solutionText,
                        { line: line, ch: freeMarkedSpans[0].from },
                        { line: line, ch: freeMarkedSpans[0].to }
                    
                    editor.markText { line: line, ch: freeMarkedSpans[0].from },
                        { line: line, ch: freeMarkedSpans[0].from + solutionText.length },
                        { className: 'free-number' }

                    reparseLine line
                    
                catch e
                    debugger
                    console.log 'The numeric solver was unable to solve this equation!', e

            else
                Cr.setLineState line, 'underDetermined'
                console.log 'This equation cannot be solved! Too much freedom', freeMarkedSpans

        editor.off 'change', fixOnChange
        editor.on 'change', onChange

    onChange = (instance, changeObj) ->
        # executes on user or cruncher change to text
        # (except during evalLine)
        return if not editor

        line = changeObj.to.line
        evalLine line
    
    editor.on 'change', onChange

    nearestValue = (pos) ->
        # find nearest number (Value) to pos = { line, ch }
        # used for identifying hover/drag target

        parsed = parsedLines[pos.line]
        return unless parsed?

        nearest = null
        for value in parsed.values
            if value.start <= pos.ch <= value.end
                nearest = value
                console.log nearest
                break

        return nearest

    draggingState = null

    ($ document).on('mouseenter', '.cm-number', (enterEvent) ->
        # add hover class, construct number widget
        # when user hovers over a number
        
        if draggingState? then return

        hoverPos = editor.coordsChar
            left: enterEvent.pageX
            top: enterEvent.pageY

        hoverValue = nearestValue hoverPos

        if not hoverValue?
            hoverPos = editor.coordsChar
                left: enterEvent.pageX
                top: enterEvent.pageY + 2 # ugly hack because coordsChar's hit box doesn't quite line up with the DOM hover hit box

            hoverValue = nearestValue hoverPos
        
        console.log hoverValue

        if hoverValue?
            ($ '.hovering-number').removeClass 'hovering-number'
            
            ($ '.number-widget').stop(true)

            ($ this).addClass 'hovering-number'
            
            (new Cr.NumberWidget hoverValue,
                hoverPos,
                (line) -> evalLine line).show()
        
    ).on 'mousedown', '.cm-number:not(.free-number)', (downEvent) ->
        # initiate and handle dragging/scrubbing behavior
        
        ($ this).addClass 'dragging-number'
        ($ '.number-widget').remove()

        draggingState = dr = {}
        
        dr.origin = editor.getCursor()
        
        value = nearestValue dr.origin
        
        dr.num = value.num
        dr.fixedDigits = value.toString().split('.')[1]?.length ? 0
        
        dr.from = line: dr.origin.line, ch: value.start
        dr.to = line: dr.origin.line, ch: value.end

        xCenter = downEvent.pageX
        
        ($ document).mousemove((moveEvent) =>
            editor.setCursor dr.from # disable selection

            xOffset = moveEvent.pageX - xCenter
            xCenter = moveEvent.pageX
            
            delta = if xOffset >= 2 then 1 else if xOffset <= -2 then -1 else 0
            console.log xOffset / (Math.abs xOffset)

            if delta != 0
                dr.num += delta
                
                numString = dr.num.toFixed dr.fixedDigits
                editor.replaceRange numString, dr.from, dr.to

                dr.to.ch = dr.from.ch + numString.length
        ).mouseup =>
            ($ '.dragging-number').removeClass 'dragging-number'

            ($ document).unbind('mousemove')
                .unbind 'mouseup'

            editor.setCursor dr.origin

            draggingState = dr = null

    editor.refresh()

    for line in [0..editor.lineCount() - 1]
        evalLine line
