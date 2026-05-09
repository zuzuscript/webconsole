(function () {
	'use strict';

	var KEYWORDS = new Set( [
		'and', 'as', 'assert', 'but', 'case', 'catch', 'class', 'const', 'continue',
		'debug', 'default', 'die', 'does', 'else', 'extends', 'false', 'fn', 'for',
		'from', 'function', 'if', 'import', 'in', 'instanceof', 'last', 'let',
		'method', 'new', 'next', 'not', 'null', 'or', 'return', 'self', 'static',
		'super', 'switch', 'throw', 'trait', 'true', 'try', 'unless', 'warn',
		'while', 'with', 'can', 'eq', 'ne', 'gt', 'ge', 'lt', 'le', 'cmp',
		'eqi', 'nei', 'gti', 'gei', 'lti', 'lei', 'cmpi', 'mod', 'xor', 'nand',
		'typeof', 'union', 'intersection', 'subsetof', 'supersetof', 'equivalentof',
		'say', 'print'
	] );

	var BUILTIN_TYPES = new Set( [
		'Array', 'Bag', 'Boolean', 'Class', 'Collection', 'Dict', 'Function',
		'Number', 'Object', 'Pair', 'PairList', 'Set', 'String', 'Trait'
	] );

	function escapeHtml( text ) {
		return text
			.replace( /&/g, '&amp;' )
			.replace( /</g, '&lt;' )
			.replace( />/g, '&gt;' );
	}

	function classifyToken( token ) {
		if ( /^\s+$/.test( token ) ) {
			return 'ws';
		}

		if ( /^\/\//.test( token ) || /^\/\*/.test( token ) ) {
			return 'comment';
		}

		if ( /^(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)$/s.test( token ) ) {
			return 'string';
		}

		if ( /^(?:0x[\da-f]+|0b[01]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)$/i.test( token ) ) {
			return 'number';
		}

		if ( /^(?:\?:=|\?:|=>|->|→|\.\.|\.\.\.|<=>|==|!=|<=|>=|≠|≤|≥|≡|≢|≶|≷|\+\+|--|[+\-*/%<>=!?:|&.^~×÷⋀⋁⊻⊼¬∈∉⋃⋂∖\\⊂⊃«»])$/.test( token ) ) {
			return 'operator';
		}

		if ( /^(?:\{\{|\}\}|<<|>>|[{}()[\],;.])$/.test( token ) ) {
			return 'punct';
		}

		if ( /^[A-Za-z_][\w$]*$/.test( token ) && KEYWORDS.has( token ) ) {
			return 'keyword';
		}

		if ( /^[A-Za-z_][\w$]*$/.test( token ) && BUILTIN_TYPES.has( token ) ) {
			return 'keyword';
		}

		if ( /^[A-Za-z_][\w$]*$/.test( token ) ) {
			return 'ident';
		}

		return 'plain';
	}

	function tokenize( source ) {
		var tokenPattern = /(\/\/[^\n]*|\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|0x[\da-fA-F]+|0b[01]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?|\?:=|\?:|=>|->|→|\{\{|\}\}|<<|>>|«|»|\.\.\.|\.\.|<=>|==|!=|<=|>=|≠|≤|≥|≡|≢|≶|≷|\+\+|--|[+\-*/%<>=!?:|&.^~×÷⋀⋁⊻⊼¬∈∉⋃⋂∖\\⊂⊃]|[{}()[\],;.]|\s+|[A-Za-z_][\w$]*)/g;
		var html = '';
		var match;
		var lastIndex = 0;

		while ( ( match = tokenPattern.exec( source ) ) !== null ) {
			if ( match.index > lastIndex ) {
				html += escapeHtml( source.slice( lastIndex, match.index ) );
			}

			var token = match[0];
			var type = classifyToken( token );
			if ( type === 'ws' || type === 'plain' ) {
				html += escapeHtml( token );
			} else {
				html += '<span class="zuzu-hl-' + type + '">' + escapeHtml( token ) + '</span>';
			}

			lastIndex = tokenPattern.lastIndex;
		}

		if ( lastIndex < source.length ) {
			html += escapeHtml( source.slice( lastIndex ) );
		}

		return html;
	}

	var historyEl = document.getElementById( 'history' );
	var promptEl = document.getElementById( 'current-prompt' );
	var inputEl = document.getElementById( 'editor-input' );
	var highlightEl = document.getElementById( 'editor-highlight-code' );
	var highlightBoxEl = document.getElementById( 'editor-highlight' );
	var runBtn = document.getElementById( 'run-btn' );
	var resetBtn = document.getElementById( 'reset-btn' );
	var sessionStorageKey = 'zuzu_webconsole_sid';
	var sessionId = window.localStorage.getItem( sessionStorageKey ) || '';

	var expectingMore = false;

	function promptText() {
		return expectingMore ? 'zuzu (...)>' : 'zuzu (^_^)> ';
	}

	function updatePrompt() {
		promptEl.textContent = promptText();
		promptEl.classList.toggle( 'cont', expectingMore );
	}

	function renderInput() {
		highlightEl.innerHTML = tokenize( inputEl.value || '' ) + '\n';
		highlightBoxEl.scrollTop = inputEl.scrollTop;
		highlightBoxEl.scrollLeft = inputEl.scrollLeft;
	}

	function appendHistoryEntry( source, status, message ) {
		var entry = document.createElement( 'div' );
		entry.className = 'entry status_' + status;

		if ( status === 'submitted' ) {
			var prompt = document.createElement( 'div' );
			prompt.className = 'prompt' + ( expectingMore ? ' cont' : '' );
			prompt.textContent = promptText();
			entry.appendChild( prompt );
		}

		if ( status === 'submitted' ) {
			var code = document.createElement( 'pre' );
			code.className = 'zuzu-highlight';
			var codeInner = document.createElement( 'code' );
			codeInner.innerHTML = tokenize( source );
			code.appendChild( codeInner );
			entry.appendChild( code );
		}

		if ( status === 'ok' || status === 'error' ) {
			var out = document.createElement( 'div' );
			out.className = 'output' + ( status === 'error' ? ' error' : '' );
			out.textContent = message;
			entry.appendChild( out );
		}

		if ( status === 'stderr' || status === 'stdout' ) {
			var out = document.createElement( 'div' );
			out.className = 'output ' + status;
			out.textContent = message;
			entry.appendChild( out );
		}

		historyEl.appendChild( entry );
		historyEl.scrollTop = historyEl.scrollHeight;
	}

	function appendStreamOutput( text, kind ) {
		if ( !text ) {
			return;
		}

		var streamLines = text.replace( /\n$/, '' );
		if ( streamLines === '' ) {
			return;
		}

		appendHistoryEntry(
			'',
			kind,
			streamLines
		);
	}

	function postEval( payload ) {
		var effectivePayload = Object.assign( {}, payload );
		if ( sessionId ) {
			effectivePayload.sid = sessionId;
		}

		return fetch( './api/eval', {
			method: 'POST',
			headers: {
				'Content-Type': 'application/json'
			},
			credentials: 'same-origin',
			body: JSON.stringify( effectivePayload )
		} ).then( function ( res ) {
			return res.json();
		} ).then( function ( data ) {
			if ( typeof data.sid === 'string' && data.sid !== '' ) {
				sessionId = data.sid;
				window.localStorage.setItem( sessionStorageKey, sessionId );
			}
			return data;
		} );
	}

	function runInput() {
		var source = inputEl.value;
		if ( source.trim() === '' && !expectingMore ) {
			return;
		}

		appendHistoryEntry( source, 'submitted' );

		postEval( { line: source } ).then( function ( data ) {
			if ( data.status === 'ok' ) {
				appendStreamOutput( data.stdout, 'stdout' );
				appendStreamOutput( data.stderr, 'stderr' );
				appendHistoryEntry( '', 'ok', data.output );
				expectingMore = false;
			}
			else if ( data.status === 'error' ) {
				appendStreamOutput( data.stdout, 'stdout' );
				appendStreamOutput( data.stderr, 'stderr' );
				appendHistoryEntry( '', 'error', data.error );
				expectingMore = false;
			}
			else if ( data.status === 'continue' ) {
				expectingMore = true;
			}
			else {
				expectingMore = false;
			}

			inputEl.value = '';
			renderInput();
			updatePrompt();
			inputEl.focus();
		} ).catch( function ( err ) {
			appendHistoryEntry( '', 'error', 'Request failed: ' + err );
			expectingMore = false;
			updatePrompt();
		} );
	}

	function resetSession() {
		postEval( { reset: true, line: '' } ).then( function () {
			expectingMore = false;
			historyEl.innerHTML = '';
			inputEl.value = '';
			renderInput();
			updatePrompt();
			inputEl.focus();
		} ).catch( function ( err ) {
			appendHistoryEntry( '', 'error', 'Reset failed: ' + err );
		} );
	}

	inputEl.addEventListener( 'input', renderInput );
	inputEl.addEventListener( 'scroll', function () {
		highlightBoxEl.scrollTop = inputEl.scrollTop;
		highlightBoxEl.scrollLeft = inputEl.scrollLeft;
	} );
	inputEl.addEventListener( 'keydown', function ( event ) {
		if ( event.key === 'Enter' && !event.shiftKey ) {
			event.preventDefault();
			runInput();
		}
	} );

	runBtn.addEventListener( 'click', runInput );
	resetBtn.addEventListener( 'click', resetSession );

	renderInput();
	updatePrompt();
	inputEl.focus();
})();
