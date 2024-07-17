# Struct Class in LuaJIT

[![Donate via Stripe](https://img.shields.io/badge/Donate-Stripe-green.svg)](https://buy.stripe.com/00gbJZ0OdcNs9zi288)<br>

Example:
```
local struct = require 'struct'
local Foo_t = struct{
	name = 'Foo_t',
	fields = {
		{exampleField = 'fieldCType'},
	},
	-- optional: add any metatable index functions:
	metatable = function(m)
		function m:bar()
			print('Foo:bar '..self.exampleField)
		end
	end,
}
```

This automatically creates the field and calls ffi.cdef
