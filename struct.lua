--[[
This was first a way to collect reflection, iteration, and serialization info alongside luajit ffi structs.
Then it became a way to save code between languages (cpp and c) and reuse it between C / OpenCL typedef's and LuaJIT ffi.cdef's.
It gets more complicated when you look at how hydro-cl would define structs but defer defining their ffi.cdefs until later for some odd reason.
Now I'm trying to stretch it more for use of luajit anonymous structs and metatypes, which are designed to mimic C++ (though this necessitates the $ type arguments everywhere, which the C typedef code interoperability does not appreciate).


TODO
- should I use a static functin for creating struct subclasses (instead of overriding the struct ctor) ?
- helper function for counting dense size (of all fields ... max for union, sum for struct)
- helper function for making a union + ptr + struct (since it was common enough)
- always return the metatable?
- don't define bits or arrays in the .type string, instead use numbers/Lua keys .bits and .array

I could replace all types with ffi ctype objects *except*
- bitfields
- arrays that are sized by [?] parameter

where is this used?
	cl/obj/env.lua
	efesoln-cl/efe.lua
	super_metroid_randomizer/
	ff6-hacking/editor-lua
	ff6-hacking/zst-hacking/decode/zst-patch.lua
	ff6-randomizer/
	ljvm/
	mesh/readfbx.lua
	vec-ffi/create_vec.lua
	hydro-cl
	modules
--]]
local ffi = require 'ffi'
local table = require 'ext.table'
local assert = require 'ext.assert'
local string = require 'ext.string'
local op = require 'ext.op'
local class = require 'ext.class'
local template = require 'template'
local showcode = require 'template.showcode'

local struct = class()

-- [=[ begin functions for child metatable classes

-- 'isa' for Lua classes and ffi metatypes
-- TODO similar to ext.class ...
-- TODO TODO it's probably a bad idea to have this handle strings as if they're types ...
-- it is ugly enough that it handles Lua table metatypes *and* ffi cdata
function struct.isa(cl, obj)
--DEBUG(struct):print('struct.isa(cl='..tostring(cl)..', obj='..tostring(obj)..')')
	-- if we get a ffi.typeof() then it will be cdata as well, but luckily in ffi, typeof(typeof(x)) == typeof(x)
	local luatype = type(obj)
--DEBUG(struct):print('got obj lua type', luatype)
	if luatype == 'string'
	or luatype == 'cdata'
	then
		-- luajit is gung-ho on the exceptions, even in cases when identical Lua behavior doesn't throw them (e.g. Lua vs cdata indexing fields that don't exist)
		local res
--DEBUG(struct):print('converting obj to cdata...')
		res, obj = pcall(ffi.typeof, obj)
--DEBUG(struct):print('... got ffi.typeof(cdata) to be', res, obj)
		if not res then return false end
	elseif luatype ~= 'table' then
	--	return false
	-- else return false?
	end
	local isaSet = op.safeindex(obj, 'isaSet')
--DEBUG(struct):print('isaSet for obj', isaSet)
	if not isaSet then
--DEBUG(struct):print('isaSet not found - failing')
		return false
	end
--DEBUG(struct):print('isaSet[cl]', isaSet[cl])

	if isaSet[cl] then return true end

	-- another luajit ffi quirk ... two ctype cdata's can be __eq, but still have different table key hashes ...
	-- and another, you can't getmetatable() on ctype.  so the metatable is lost as soon as you make it.  great.
	-- therefore, time to use the .metatable that i'm storing in the ctype __index ...
	local mt = op.safeindex(cl, 'metatable')
--DEBUG(struct):print('cl mt', mt)
--DEBUG(struct):print('isaSet[mt]', isaSet[mt])
	if isaSet[mt] then return true end

--DEBUG(struct):print'...failed'
	return false
end

-- iterate across all named fields of the struct
-- including anonymous-inner structs
-- TODO just use __pairs ? though note that __pairs metamethod doesn't exist in <=5.1
function struct:fielditer()
	return self.fielditerinner, {
		self = self,
		fields = table(self.fields),
	}
end
-- static method, used with the fielditer
function struct.fielditerinner(state)
	local self = state.self
	if #state.fields == 0 then return end
	local field = state.fields:remove(1)
	if field.no_iter then return struct.fielditerinner(state) end

	local ctype = field.type
	if field.name then
		assert(not (field.anonymous or field.ctypeOnly))
		return field.name, ctype, field
	end
	assert(ctype.anonymous or ctype.ctypeOnly)
	if struct:isa(ctype) then
		assert(ctype.fields)
		for i=#ctype.fields,1,-1 do
			state.fields:insert(1, ctype.fields[i])
		end
		return struct.fielditerinner(state)
	end
end

function struct:toLua()
	local result = {}
	for name, ctype, field in self:fielditer() do
		if not field.no_tolua then
			local value = self[name]
			if struct:isa(ctype) then	-- TODO just test .toLua ?
				value = value:toLua()
			end
			result[name] = value
		end
	end
	return result
end

function struct.dectostr(value)
	return ('%d'):format(value)
end

function struct.hextostr(digits)
	return function(value)
		return ('%0'..digits..'x'):format(value)
	end
end

struct.typeToString = {
	uint8_t = struct.dectostr,
	uint16_t = struct.dectostr,
}

function struct:fieldToString(name, ctype)
	if struct:isa(ctype) then
		ctype = ctype.name
	end
	-- special for bitflags ...
	if type(ctype) == 'string'
	and ctype:sub(-2) == ':1'
	then
		if self[name] ~= 0 then
			return 'true'
		else
			return 'false' -- nothing
		end
	end

	-- I wanted to make it so you can override 'typeToString' in the metatable but
	-- hmm not working so well.  is the key `ctype` correct?  does the key exist?
	local t = op.safeindex(self, 'typeToString') or struct.typeToString
	local f = t and t[ctype] or tostring
	return f(self[name])
end

struct.__concat = string.concat

-- assigned to metatable.new
-- I'd put it in struct:new, but that's already being used to create new structs...
local function newmember(mt, ...)
	return ffi.new(mt.name, ...)
end

-- this depends on :unpack() , which is defined in the codegen below
-- TODO between this and ffi.cpp.vector, one is toTable the other is totable ... which to use?
function struct:toTable()
	return {self:unpack()}
end

--]=] end functions for child metatable classes

--[[
this generate both the C and C++ code
then ffi.cdef's the C code only

args:
	name = (optional) struct name

	anonymous = (optional) set to 'true' for inner-anonymous structs
		NOTICE:
			It used to be that 'anonymous' was a flags for inner structs that didnt get names.
			Now I'm using 'anonymous' is for outer structs that don't get a name in `ffi.cdef`, but still get metatype info.
			As a result of design (and compat with my opencl apps), 'anonymous' outer type will not match the 'anonymous' inner structs who just have the same struct code inserted.
			I cuold use identical types in luajit using the $ type parameters, but then I'd need to grep in the inline code to produce correct C code for my OpenCL projects.
			Maybe I'll do that later ... keep codes.c, codes.cpp, and codes.luajit, and a list of luajit type args to go with it?

	ctypeOnly = (optional) this is my flag for using a struct with `ffi.typeof` only.
		Not the old `anonymous`-inner class with intention of code-inlining for the sake of reuse in C or OpenCL.
		This for is strictly-LuaJIT-FFI ctype classes that will need lots of '$' arguments.
		This implies `cdef=false`, and it also implies no .codes generation.

	either `name` or `anonymous` or `ctypeOnly` must be set.

	union = (optional) set to 'true' for unions, default false for structs
	metatable = function(metatable) for transforming the metatable before applying it via `ffi.metatype`
	cdef = (optional) set to 'false' to avoid calling ffi.cdef on the generated code
	packedFields = (optional) set to 'true' to add __attribute__((packed)) to all fields.
	packed = (optional) set to 'true' to __attribute__((packed)) to the struct.
	body = (optional) provide extra body code for the C++ generation
	tostringFields = (optional) set to use fields in the serialization
	notostring = (optional) cheap hack to disable default tostring because it gets errors in big structures
	tostringOmitFalse = (optional) tostring method will omit 'false' values.  only works with `tostringFields`.
	tostringOmitNil = (optional) tostring method will omit 'nil' and nil values.  only works with `tostringFields`.
	tostringOmitEmpty = (optional) tostring method will omit '{}' values.  only works with `tostringFields`.

	fields = table of ...
		name = string.  required unless the type is an anonymous struct.
		type = struct-type, cdata, or ffi c type
		no_iter = (optional) set to 'true' to omit all iteration, including the following:
		no_tostring = (optional) set to 'true' to omit this from tostring
		no_tolua = (optional) set to 'true' to omit from toLua()
		... tempting to make fields just an enumeration of the integer children ...
		value = (optional) string to set as the default value
		packed = (optional) set to 'true' to add __attribute__((packed)) to this field. TODO more attributes?

TODO
- option to disable the 'typedef' for C structs and just use a `struct <name>` type?
--]]
local function newStruct(args)
	local name = args.name
	local anonymous = args.anonymous
	assert(args.name or args.anonymous or args.ctypeOnly, "expected .name or .anonymous or .ctypeOnly")
	local fields = assert(args.fields)
	assert(not struct:isa(fields))
	local codes = {}

	local ctypeOnly = not not args.ctypeOnly
	local typeofArgs
	local c_vs_cpp = ctypeOnly and {false} or {false, true}

	for _,cpp in ipairs(c_vs_cpp) do
		typeofArgs = table()	-- if I"m doing this twice (i.e. for non-ctypeOnly i.e. anonymous-inner types even those to-be-used for ctypeOnly types)
		-- then just keep the latest one
		codes[cpp and 'cpp' or 'c'] = template([=[
<?
do
	local prefix = {}
	if name and not cpp then table.insert(prefix, 'typedef') end
	table.insert(prefix, args.union and 'union' or 'struct')
	if args.packed then table.insert(prefix, '__attribute__((packed))') end
	table.insert(prefix, name)
	table.insert(prefix, '{')
	?><?=table.concat(prefix, ' ')?>
<?
end
local assert = require 'ext.assert'
assert.len(typeofArgs, 0)
local ffi = require 'ffi'
local op = require 'ext.op'
for _,field in ipairs(fields) do
	local name = field.name
	local ctype = field.type

	if not (name or op.safeindex(ctype, 'anonymous') or op.safeindex(ctype, 'ctypeOnly')) then
		error("any type let alone field (without a name) type needs either .anonymous, .name, or .ctypeOnly defined")
	end


	if not name then
		if op.safeindex(ctype, 'ctypeOnly') then
			error("I can't generate an anonymous-inline-typed field that has ctypeOnly")
		else
			if not struct:isa(ctype) then
				assert.type(ctype, 'string', "anonymous field that is not a struct?")
?> <?=ctype?>
<?
			else
				assert(ctype.anonymous)
				assert(ctype.metatable, "ok this is a field without a metatable, so it's not a struct")
				local fieldCode = assert(ctype.code, "how did you have a field without a name and without .code?")

				fieldCode = fieldCode:gsub('\n', '\n\t')
				-- now if it's anonymous then we want a trailing ;
				-- if it's not then we don't
				if not ctype.anonymous then
					fieldCode = fieldCode:match'^(.*);%s*$'
				end
				-- and TODO remind me to get rid of the trailing ; from the stored c code
?>	<?=fieldCode?>
<?
				-- if we are inlining code that has typeof args then we should append those in place too
				typeofArgs:append(ctype.typeofArgs)
			end
		end
	else	-- field has name:
		local bits
		if type(ctype) == 'string' then
			local rest
			rest, bits = ctype:match'^(.*):(%d+)$'
			if bits then
				field.bits = bits
				ctype = rest
			end
			local base, array = ctype:match'^(.*)%[([^%]]*)%]$'
			if array then
				field.array = assert(tonumber(array), "unable to parse array size "..tostring(array))
				ctype = base
				name = name .. '[' .. array .. ']'
			end
?>	<?=ctype?> <?	-- string
		elseif struct:isa(ctype) then
			if ctype.ctypeOnly then
				typeofArgs:insert(ctype)
?>	$ <? -- ctype-isa-struct
			else
				if ctype.name then
?>	<?=ctype.name?> <? -- ctype w/name
				else	-- anonymous struct <-> insert the code here
?>	<?=ctype.code?> <? -- anonymous-inline ctype
					typeofArgs:append(ctype.typeofArgs)
				end
			end
		else -- ctype is not a string and not a struct ...
			-- if it's a ctype object then ...
			-- if our struct is a ctypeOnly then we can use a $ param
			-- but if our struct is not (i.e. is meant for later C/C++/OpenCL typedef)
			--  then we will split out its type captured out of tostring and cross our fingers (which will still error in the case it's a ctype-object of an anonymous-struct, union, array, etc)
			if args.ctypeOnly then
?>	$ <?	-- ctype-object
				typeofArgs:insert(ctype)
			else
				local ctypestr = tostring(ctype)
				local ctypename = ctypestr:match'^ctype<(.*)>$'
				if ctypename then
					ctype = ctypename
					local base, array = ctype:match'^(.*)%[([^%]]*)%]$'
					if array then
						field.array = assert(tonumber(array), "unable to parse array size "..tostring(array))
						ctype = base
						name = name .. '[' .. array .. ']'
					end
				else
					error("field type is not a string or a struct: "..tostring(ctype))
				end
?>	<?=ctype?> <?	-- ctype but not struct
			end
		end
		if args.packedFields or field.packed then
			?>__attribute__((packed))<?
		end
		?><?=name and (' '..name) or ''
		?><?=bits and (' : '..bits) or ''
		?><?
		if cpp and field.value then
			?> = <?=field.value?><?
		end
		?>;
<?	end
end
if cpp and args.body then
?><?=args.body?>
<?
end
if cpp then
?>};<?
else
?>}<?=name and (' '..name) or ''?>;<?
end
?>]=],
			{
				ffi = ffi,
				name = name,
				cpp = cpp,
				fields = fields,
				struct = struct,
				args = args,
				typeofArgs = typeofArgs,
			}
		)
	end
	assert.index(codes, 'c', "how did you manage to skip defining codes.c?")

	local structType
	local metatable
	local metacode
	assert(xpcall(function()
		if args.cdef ~= false then
			if not name then
				-- cdef wants a trailing ;, non-cdef does not
				local typeofcode = codes.c:match'^(.*);%s*$'
--DEBUG:print('typeofArgs:', typeofArgs:unpack())
--DEBUG:print('BEGIN TYPEOFCODE')
--DEBUG:print(typeofcode)
--DEBUG:print('END TYPEOFCODE')

				--if ctypeOnly then
					structType = ffi.typeof(typeofcode, typeofArgs:unpack())
				--else
				--	structType = ffi.typeof(typeofcode)
				--end
			else
				if #typeofArgs > 0 then
					print([[

!!! WARNING !!!
name=]]..name..[[

If you want to define a struct with a name then you probably want to cdef it so it retains with this name in the ffi state.
However, you are also using fields containing ctypeOnly, i.e. nameless $-parameter types, which cannot be used with ffi.cdef,
so maybe you want to use `name=nil, ctypeOnly=true`?
As a result, something will probably go wrong in the next line...
]])
				end
				ffi.cdef(codes.c)
				structType = ffi.typeof(name)
			end
		end

		-- also in common with my hydro-cl project
		-- consider merging
		metatable = class(struct)
		metatable.isa = struct.isa
		metatable.name = name or false	--- so cdata doesn't error on the __index
		metatable.anonymous = anonymous
		metatable.ctypeOnly = ctypeOnly
		metatable.union = args.union
		metatable.fields = fields
		-- with luajit, ffi.typeof(cdata) returns the 'ctype' object (not the ffi.metatype)
		--  getmetatable(cdata) returns the string "ffi" (not the ffi.metatype)
		--  debug.getmetatable(cdata) returns an internal metatable (not the ffi.metatype)
		--  and ffi.metatype without a 2nd arg still just complains
		-- so is there no way to get a cdata ffi.metatype() metatable other than by setting it in the metatable's __index table?
		metatable.metatable = metatable

--[=[ store sizes in metatable, especially packed size of all fields
		--[[ hmm, why is it that sometimes the field types haven't yet been defined?  is that even possible?
		if not metatable.anonymous and args.cdef ~= false then
			metatable.sizeof = ffi.sizeof(metatable.name)
		end
		--]]

		-- calculate packed size
		-- don't use fielditer in case it's a union and we're finding the packed-size of an anonymous struct ...
		do
			local packedSize = 0
			for _,field in ipairs(metatable.fields) do
				local fieldSize
				local fieldType = field.type
				if type(fieldType) == 'string' then
					if field.bits then
						fieldSize = field.bits / 8
					else
						fieldSize = ffi.sizeof(fieldType)
					end
				elseif struct:isa(fieldType) then
					fieldSize = fieldType.sizeof or fieldType.packedSize	-- .anonymous won't have .sizeof since it has no name
					assert(fieldSize, "failed to find .sizeof or .packedSize for fieldType:\n"..require 'ext.tolua'(fieldType))
					-- TODO how to infer its name ... I don't think you can without a typedef somewhere, and that isn't compat with inner anonymous structs ... so all inner structs would need to be moved outside ...
				else
					error'here'
				end
				if union then
					packedSize = math.max(packedSize, fieldSize)
				else
					packedSize = packedSize + fieldSize
				end
			end
			metatable.packedSize = math.ceil(packedSize)
		end
--]=]

		metatable.typeofArgs = typeofArgs
		metatable.code = assert.index(codes, 'c')
		metatable.cppcode = codes.cpp

		metatable.new = newmember	-- new <-> cdata ctor.  so calling the metatable is the same as calling the cdata returned by the structType.
		metatable.subclass = nil	-- don't allow subclasses.  you can't in C after all.

		-- now that we have struct as 'metatable's metatable
		-- and we have .field assigned,
		-- we can use :fielditer()
		-- and use it to generate code (and inline some functions that would otherwise be slow)
		metacode = template([[
local ffi = require 'ffi'
local structType, metatable, args = ...

<?
local numFieldExprs = 0
for name in metatable:fielditer() do numFieldExprs = numFieldExprs + 1 end
local dontInlineTooComplex = numFieldExprs >= 10
?>


<? if not args.notostring then 	-- cheap hack to disable default tostring because it gets errors in big structures
?>
function metatable:__tostring()
	local sep = ''
	local s = '{'
<?
	for name, ctype, field in metatable:fielditer() do
		if not field.no_tostring then
		-- TODO ctype might not be a string...
		-- TODO before I had so if fieldToString returned {} then I'd just skip it
			if args.tostringFields then
				if args.tostringOmitFalse
				or args.tostringOmitNil
				or args.tostringOmitEmpty
				then
?>
	local v = self:fieldToString('<?=name?>', '<?=ctype?>')
	if true
<?					if args.tostringOmitFalse then
?>	and v ~= 'false' and v ~= false
<?					end
					if args.tostringOmitNil then
?>	and v ~= 'nil' and v ~= nil
<?					end
				if args.tostringOmitEmpty then
?>	and v ~= '{}'
<?				end
?>	then
		s = s .. sep .. '<?=name?>='..v
		sep = ', '
	end
<?
			else
?>	s = s .. sep .. '<?=name?>='..self:fieldToString('<?=name?>', '<?=ctype?>')
	sep = ', '
<?			end
		else
?>	s = s .. sep .. self:fieldToString('<?=name?>', '<?=ctype?>')
	sep = ', '
<?		end
	end
end
?>
	s = s .. '}'
	return s
end
<? end -- args.notostring
?>

metatable.__eq = function(a,b)
	if getmetatable(a) ~= getmetatable(b) then return false end
<?
-- looks like 250 expressions is the limit ...
if not dontInlineTooComplex then
	local exprs = {}
	for name, ctype in metatable:fielditer() do
		table.insert(exprs, 'a.'..name..' == b.'..name)
	end
?>	return <?=table.concat(exprs, ' and ')?>
<? else ?>
	for name in metatable:fielditer() do
		if a[name] ~= b[name] then return false end
	end
	return true
<?
end
?>
end

function metatable:unpack()
<?
if dontInlineTooComplex then
?>
	local fieldNames = {}
	for name in metatable:fielditer() do
		table.insert(fieldNames, name)
	end
	local function unpackFields(...)
		if select('#', ...) == 0 then return end
		return self[...], unpackFields(select(2, ...))
	end
	return unpackFields(table.unpack(fieldNames))
<?
else
?>
	return <?
local first = true
for name, ctype in metatable:fielditer() do
?><?=first and '' or ', '?>self.<?=name?><?
	first = false
end
?>
<? end ?>
end

-- TODO just use ffi.new ?  but that requires a typename still ...
-- also TODO, looks like if args.cdef == false then structType won't be set and this won't work
function metatable:clone()
	return structType(self:unpack())
end

-- do this in here so structType can be in here too
-- TODO performance loss due to extra closures?
-- is it worth it from the perf gain from inlining these functions?

if args.metatable then
	args.metatable(metatable, structType)
end

if args.cdef ~= false then
-- also if we were told not to cdef then we can't get a metatype
	-- 'structType' returned is the ffi.typeof(name)
	if metatable.name then
		structType = ffi.metatype(metatable.name, metatable)
	else
		structType = ffi.metatype(structType, metatable)
	end
end
]], {
	args = args,
	metatable = metatable,
})
		assert(load(metacode))(structType, metatable, args)
--[[
print('\n'
			..(codes.c and ('c code:\n'
			..showcode(codes.c)..'\n') or '')
			..(codes.cpp and ('c++ code:\n'
			..showcode(codes.cpp)..'\n') or '')
			..(metacode and ('inline metamethod code:\n'
			..showcode(metacode)..'\n') or '')
			..tostring(err)..'\n'
			..debug.traceback()
)
--]]
	end, function(err)
		return '\n'
			..(codes.c and ('c code:\n'
			..showcode(codes.c)..'\n') or '')
			..(codes.cpp and ('c++ code:\n'
			..showcode(codes.cpp)..'\n') or '')
			..(metacode and ('inline metamethod code:\n'
			..showcode(metacode)..'\n') or '')
			..' typeofArgs='..require'ext.tolua'(typeofArgs)..'\n'
			..tostring(err)..'\n'
			..debug.traceback()
	end))

	assert(struct:isa(metatable))

	-- wait is this true? when is struct set in the metatype's isaSet?
	--[[
	fun fact, ffi.metatype will set the metatable to both any ffi.new/cast instances of the C type
	but also to the result of ffi.typeof() of the C type
	but the typeof() isn't the same as an instance, right?
	how come the typeof() gets the metatable too?
	weird
	but why I'm commenting this?
	because in libffi it doesn't set the ctype's metatable, it only sets the ffi.new/cast instances' metatables
	--]]
	--[[
	if metatype then
		assert(struct:isa(metatype))
	end
	--]]

	-- We still have to return metatable in the event structType wasn't defined, in the event that 'cdef=false' was provided
	-- ... namely, for hydro-cl's sake.
	return structType or metatable
end

-- instead of creating a struct instance, create a metatype subclass
function struct:new(...)
	return newStruct(...)
end

-- 'struct' is / should be the parent class of all created structures
return struct
