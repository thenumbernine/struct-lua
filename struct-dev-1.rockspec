package = "struct"
version = "dev-1"
source = {
	url = "git+https://github.com/thenumbernine/struct-lua"
}
description = {
	summary = [[luajit struct generation helper]],
	detailed = [[luajit struct generation helper]],
	homepage = "https://github.com/thenumbernine/struct-lua",
	license = "MIT"
}
dependencies = {
	"lua >= 5.1",
}
build = {
	type = "builtin",
	modules = {
		struct = "struct.lua"
	}
}
