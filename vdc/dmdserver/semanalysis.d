// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2012 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt

module vdc.dmdserver.semanalysis;

import vdc.dmdserver.dmdinit;
import vdc.dmdserver.dmderrors;
import vdc.dmdserver.semvisitor;
import vdc.ivdserver;

import dmd.arraytypes;
import dmd.cond;
import dmd.dmodule;
import dmd.dsymbolsem;
import dmd.errors;
import dmd.globals;
import dmd.identifier;
import dmd.semantic2;
import dmd.semantic3;

__gshared AnalysisContext lastContext;

struct ModuleInfo
{
	Module parsedModule;
	Module semanticModule;

	Module createSemanticModule()
	{
		Module m = cloneModule(parsedModule);
		m.importedFrom = m;
		m.resolvePackage(); // adds module to Module.amodules (ignore return which could be module with same name)
		semanticModule = m;
		Module.modules.insert(m);
		return m;
	}
}

// context is kept as long as the options don't change
class AnalysisContext
{
	Options options;

	ModuleInfo[] modules;

	int findModuleInfo(Module parsedMod)
	{
		foreach (ref i, inf; modules)
			if (parsedMod is inf.parsedModule)
				return cast(int) i;
		return -1;
	}
	int findModuleInfo(const(char)[] filename)
	{
		foreach (ref i, inf; modules)
			if (filename == inf.parsedModule.srcfile.toString())
				return cast(int)i;
		return -1;
	}
}

// is the module already added implicitly during semantic analysis?
Module findInAllModules(const(char)[] filename)
{
	foreach(m; Module.amodules)
	{
		if (m.srcfile.toString() == filename)
			return m;
	}
	return null;
}

//
Module analyzeModule(Module parsedModule, const ref Options opts)
{
	int rootModuleIndex = -1;
	bool needsReinit = true;

	if (!lastContext)
		lastContext = new AnalysisContext;
	AnalysisContext ctxt = lastContext;

	auto filename = parsedModule.srcfile.toString();
	int idx = ctxt.findModuleInfo(filename);
	if (ctxt.options == opts)
	{
		if (idx >= 0)
		{
			if (parsedModule !is ctxt.modules[idx].parsedModule)
			{
				// module updated, replace it
				ctxt.modules[idx].parsedModule = parsedModule;

				// TODO: only update dependent modules
			}
			else
			{
				if (!ctxt.modules[idx].semanticModule)
				{
					auto m = ctxt.modules[rootModuleIndex].createSemanticModule();
					m.importAll(null);
				}
				needsReinit = false;
			}
			rootModuleIndex = idx;
		}
		else
		{
			ctxt.modules ~= ModuleInfo(parsedModule);
			rootModuleIndex = cast(int)(ctxt.modules.length - 1);

			// is the module already added implicitly during semantic analysis?
			auto ma = findInAllModules(filename);
			if (ma is null)
			{
				// if not, no other module depends on it, so just append
				auto m = ctxt.modules[rootModuleIndex].createSemanticModule();
				m.importAll(null);
				needsReinit = false;
			}
			else
			{
				// TODO: check if the same as m
				auto m = ctxt.modules[rootModuleIndex].createSemanticModule();
				m.importAll(null);
				// TODO: only update dependent modules
			}
		}
	}
	else
	{
		ctxt.options = opts;
		dmdSetupParams(opts);

		if (idx >= 0)
		{
			ctxt.modules[idx].parsedModule = parsedModule;
			rootModuleIndex = idx;
		}
		else
		{
			ctxt.modules ~= ModuleInfo(parsedModule);
			rootModuleIndex = cast(int)(ctxt.modules.length - 1);
		}
	}

	Module.loadModuleHandler = (const ref Loc location, IdentifiersAtLoc* packages, Identifier ident)
	{
		// only called if module not found in Module.amodules
		return Module.loadFromFile(location, packages, ident);
	};

	if (needsReinit)
	{
		dmdReinit();

		foreach(ref mi; ctxt.modules)
		{
			mi.createSemanticModule();
		}

		version(none) // do this lazily
		foreach(ref mi; ctxt.modules)
		{
			mi.semanticModule.importAll(null);
		}
	}

	Module.rootModule = ctxt.modules[rootModuleIndex].semanticModule;
	Module.rootModule.importAll(null);
	Module.rootModule.dsymbolSemantic(null);
	Module.dprogress = 1;
	Module.runDeferredSemantic();
	Module.rootModule.semantic2(null);
	Module.runDeferredSemantic2();
	Module.rootModule.semantic3(null);
	Module.runDeferredSemantic3();

	return Module.rootModule;
}

////////////////////////////////////////////////////////////////
//version = traceGC;
//import tracegc;
extern(Windows) void OutputDebugStringA(const(char)* lpOutputString);

string[] guessImportPaths()
{
	import std.file;

	if (std.file.exists(r"c:\s\d\dlang\druntime\import\object.d"))
		return [ r"c:\s\d\dlang\druntime\import", r"c:\s\d\dlang\phobos" ];
	if (std.file.exists(r"c:\s\d\rainers\druntime\import\object.d"))
		return [ r"c:\s\d\rainers\druntime\import", r"c:\s\d\rainers\phobos" ];
	return [ r"c:\d\dmd2\src\druntime\import", r"c:\s\d\rainers\src\phobos" ];
}

unittest
{
	import core.memory;

	dmdInit();
	dmdReinit();
	lastContext = null;

	Options opts;
	opts.predefineDefaultVersions = true;
	opts.x64 = true;
	opts.msvcrt = true;
	opts.warnings = true;
	opts.unittestOn = true;
	opts.importDirs = guessImportPaths();

	auto filename = "source.d";

	static void assert_equal(S, T)(S s, T t)
	{
		if (s == t)
			return;
		assert(false);
	}

	Module checkErrors(string src, string expected_err)
	{
		initErrorMessages(filename);
		Module parsedModule = createModuleFromText(filename, src);
		assert(parsedModule);
		Module m = analyzeModule(parsedModule, opts);
		auto err = getErrorMessages();
		auto other = getErrorMessages(true);
		assert_equal(err, expected_err);
		assert_equal(other, "");
		return m;
	}

	void checkTip(Module analyzedModule, int line, int col, string expected_tip)
	{
		string tip = findTip(analyzedModule, line, col, line, col + 1);
		assert_equal(tip, expected_tip);
	}

	void checkDefinition(Module analyzedModule, int line, int col, string expected_fname, int expected_line, int expected_col)
	{
		string file = findDefinition(analyzedModule, line, col);
		assert_equal(file, expected_fname);
		assert_equal(line, expected_line);
		assert_equal(col, expected_col);
	}

	void checkBinaryIsInLocations(string src, Loc[] locs)
	{
		initErrorMessages(filename);
		Module parsedModule = createModuleFromText(filename, src);
		auto err = getErrorMessages();
		assert(err == null);
		assert(parsedModule);
		Loc[] locdata = findBinaryIsInLocations(parsedModule);
		assert(locdata.length == locs.length);
	L_nextLoc:
		foreach(i; 0 .. locdata.length)
		{
			// not listed twice
			foreach(ref loc; locdata[i+1 .. $])
				assert(locdata[i].linnum != loc.linnum || locdata[i].charnum != loc.charnum);
			// found in results
			foreach(ref loc; locs)
				if(locdata[i].linnum == loc.linnum && locdata[i].charnum == loc.charnum)
					continue L_nextLoc;
			assert(false);
		}
	}

	void checkExpansions(Module analyzedModule, int line, int col, string tok, string[] expected)
	{
		import std.algorithm, std.array;
		string[] expansions = findExpansions(analyzedModule, line, col, tok);
		expansions.sort();
		expected.sort();
		assert_equal(expansions.length, expected.length);
		for (size_t i = 0; i < expansions.length; i++)
			assert_equal(expansions[i].split(':')[0], expected[i]);
	}

	void checkIdentifierTypes(Module analyzedModule, IdTypePos[][string] expected)
	{
		static void assert_equalPositions(IdTypePos[] s, IdTypePos[] t)
		{
			assert_equal(s.length, t.length);
			assert_equal(s[0].type, t[0].type);
			foreach (i; 1.. s.length)
				assert_equal(s[i], t[i]);
		}
		import std.algorithm, std.array, std.string;
		auto idtypes = findIdentifierTypes(analyzedModule);
		assert_equal(idtypes.length, expected.length);
		auto ids = idtypes.keys();
		ids.sort();
		foreach (i, id; ids)
			assert_equalPositions(idtypes[id], expected[id]);
	}

	static struct TextPos
	{
		int line;
		int column;
	}
	void checkReferences(Module analyzedModule, int line, int col, TextPos[] expected)
	{
		import std.algorithm, std.array, std.string;
		auto refs = findReferencesInModule(analyzedModule, line, col);
		assert_equal(refs.length, expected.length);
		for (size_t i = 0; i < refs.length; i++)
		{
			assert_equal(refs[i].loc.linnum, expected[i].line);
			assert_equal(refs[i].loc.charnum, expected[i].column);
		}
	}

	void dumpAST(Module mod)
	{
		import dmd.root.outbuffer;
		import dmd.hdrgen;
		auto buf = OutBuffer();
		buf.doindent = 1;
		moduleToBuffer(&buf, mod);

		OutputDebugStringA(buf.peekChars);
	}

	string source;
	Module m;
	source = q{
		int main()
		{
			return abc;
		}
	};
	m = checkErrors(source, "4,10,4,11:Error: undefined identifier `abc`\n");

	version(traceGC)
	{
		wipeStack();
		GC.collect();
	}

	//_CrtDumpMemoryLeaks();
	version(traceGC)
		dumpGC();

	source = q{
		import std.stdio;
		int main(string[] args)
		{
			int xyz = 7;
			writeln(1, 2, 3);
			return xyz;
		}
	};

	for (int i = 0; i < 1; i++) // loop for testing GC leaks
	{
		m = checkErrors(source, "");

		version(traceGC)
		{
			wipeStack();
			GC.collect();

			//_CrtDumpMemoryLeaks();
			//dumpGC();
		}

		//core.memory.GC.Stats stats = GC.stats();
		//trace_printf("GC stats: %lld MB used, %lld MB free\n", cast(long)stats.usedSize >> 20, cast(long)stats.freeSize >> 20);

		version(traceGC)
			if (stats.usedSize > (200 << 20))
				dumpGC();
	}

	checkTip(m, 5, 8, "(local variable) `int xyz`");
	checkTip(m, 5, 10, "(local variable) `int xyz`");
	checkTip(m, 5, 11, "");
	checkTip(m, 6, 8, "`void std.stdio.writeln!(int, int, int)(int _param_0, int _param_1, int _param_2) @safe`");
	checkTip(m, 7, 11, "(local variable) `int xyz`");

	version(traceGC)
	{
		wipeStack();
		GC.collect();
	}

	checkDefinition(m, 7, 11, "source.d", 5, 8); // xyz

	//checkTypeIdentifiers(source);

	source =
	q{	module pkg.source;               // Line 1
		int main(in string[] args)
		in(args.length > 1) in{ assert(args.length > 1); }
		do {
			static if(is(typeof(args[0]) : string)) { // Line 5
				if (args[0] is args[1]) {}
				else if (args[1] !is args[0]) {}
			}
			int[string] aa;
			if (auto p = args[0] in aa)  // Line 10
				if (auto q = args[1] !in aa) {}
			return 0;
		}
		static if(is(bool))
			bool t = null is null;       // Line 15
		else
			bool f = 0 in [1:1];

		enum EE { E1 = 3, E2 }
		void foo()                       // Line 20
		{
			auto ee = EE.E1;
		}
		import core.cpuid : cpu_vendor = vendor, processor;
		import cpuid = core.cpuid;       // Line 25
		string cpu_info()
		{
			return cpu_vendor ~ " " ~ processor;
		}
	};
	checkBinaryIsInLocations(source, [Loc(null, 6, 17), Loc(null, 7, 23),
									  Loc(null, 10, 25), Loc(null, 11, 26),
									  Loc(null, 15, 18), Loc(null, 17, 15)]);

	m = checkErrors(source, "");

	checkTip(m,  2, 24, "(parameter) `const(string[]) args`"); // function arg
	checkTip(m,  3,  6, "(parameter) `const(string[]) args`"); // in contract
	checkTip(m,  3, 34, "(parameter) `const(string[]) args`"); // in contract
	checkTip(m,  5, 24, "(parameter) `const(string[]) args`"); // static if is typeof expression
	checkTip(m,  6, 10, "(parameter) `const(string[]) args`"); // if expression
	checkTip(m, 11, 21, "(parameter) `const(string[]) args`"); // !in expression

	checkTip(m, 19,  9, "(enum) `pkg.source.EE`"); // enum EE
	checkTip(m, 19, 13, "(enum value) `pkg.source.EE.E1 = 3`"); // enum E1
	checkTip(m, 19, 21, "(enum value) `pkg.source.EE.E2 = 4`"); // enum E2
	checkTip(m, 22, 14, "(enum) `pkg.source.EE`"); // enum EE
	checkTip(m, 22, 17, "(enum value) `pkg.source.EE.E1 = 3`"); // enum E1

	checkTip(m,  1,  9, "(package) `pkg`");
	checkTip(m,  1, 13, "(module) `pkg.source`");
	checkTip(m, 24, 10, "(package) `core`");
	checkTip(m, 24, 15, "(module) `core.cpuid`");
	checkTip(m, 24, 23, "(alias) `pkg.source.cpu_vendor = string core.cpuid.vendor() pure nothrow @nogc @property @trusted`");
	checkTip(m, 24, 36, "(alias) `pkg.source.cpu_vendor = string core.cpuid.vendor() pure nothrow @nogc @property @trusted`");
	checkTip(m, 24, 44, "(alias) `pkg.source.processor = string core.cpuid.processor() pure nothrow @nogc @property @trusted`");
	checkTip(m, 28, 11, "`string core.cpuid.vendor() pure nothrow @nogc @property @trusted`");

	source =
	q{                                   // Line 1
		struct S
		{
			int field1 = 3;
			static long stat1 = 7;       // Line 5
			int fun(int par) { return field1 + par; }
		}
		void foo()
		{
			S anS;                       // Line 10
			int x = anS.fun(1);
		}
		int fun(S s)
		{
			auto p = new S(1);           // Line 15
			auto seven = S.stat1;
			return s.field1;
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  2, 10, "(struct) `source.S`");
	checkTip(m,  4,  8, "(field) `int source.S.field1`");
	checkTip(m,  6,  8, "`int source.S.fun(int par)`");
	checkTip(m,  6, 16, "(parameter) `int par`");
	checkTip(m,  6, 30, "(field) `int source.S.field1`");
	checkTip(m,  6, 39, "(parameter) `int par`");

	checkTip(m, 10,  4, "(struct) `source.S`");
	checkTip(m, 10,  6, "(local variable) `source.S anS`");
	checkTip(m, 11, 12, "(local variable) `source.S anS`");
	checkTip(m, 11, 16, "`int source.S.fun(int par)`");

	checkTip(m, 13, 11, "(struct) `source.S`");
	checkTip(m, 16, 19, "(thread local variable) `long source.S.stat1`");
	checkTip(m, 16, 17, "(struct) `source.S`");

	checkDefinition(m, 11, 16, "source.d", 6, 8);  // fun
	checkDefinition(m, 15, 17, "source.d", 2, 10); // S

	source =
	q{                                   // Line 1
		class C
		{
			int field1 = 3;
			static long stat1 = 7;       // Line 5
			int fun(int par) { return field1 + par; }
		}
		void foo()
		{
			C aC = new C;                // Line 10
			int x = aC.fun(1);
		}
		int fun(C c)
		{
			auto p = new C();            // Line 15
			auto seven = C.stat1;
			return c.field1;
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  2,  9, "(class) `source.C`");
	checkTip(m,  4,  8, "(field) `int source.C.field1`");
	checkTip(m,  6,  8, "`int source.C.fun(int par)`");
	checkTip(m,  6, 16, "(parameter) `int par`");
	checkTip(m,  6, 30, "(field) `int source.C.field1`");
	checkTip(m,  6, 39, "(parameter) `int par`");

	checkTip(m, 10,  4, "(class) `source.C`");
	checkTip(m, 10, 15, "(class) `source.C`");
	checkTip(m, 10,  6, "(local variable) `source.C aC`");
	checkTip(m, 11, 12, "(local variable) `source.C aC`");
	checkTip(m, 11, 16, "`int source.C.fun(int par)`");

	checkTip(m, 13, 11, "(class) `source.C`");
	checkTip(m, 16, 19, "(thread local variable) `long source.C.stat1`");
	checkTip(m, 16, 17, "(class) `source.C`");

	checkDefinition(m, 11, 16, "source.d", 6, 8);  // fun
	checkDefinition(m, 15, 17, "source.d", 2, 9);  // C

	// enum value
	source =
	q{                                   // Line 1
		enum TTT = 9;
		void fun()
		{
			int x = TTT;                // Line 5
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  2,  8, "(constant) `int source.TTT = 9`");
	checkTip(m,  5, 13, "(constant) `int source.TTT = 9`");

	// template struct without instances
	source =
	q{                                   // Line 1
		struct ST(T)
		{
			T f;
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  2, 10, "(struct) `source.ST(T)`");
	checkTip(m,  4,  4, "(unresolved type) `T`");
	checkTip(m,  4,  6, "`T f`");

	source =
	q{                                   // Line 1
		inout(Exception) foo(inout(char)* ptr)
		{
			int x = 1;
			try
			{
				x++;
			}
			catch(Exception e)
			{                            // Line 10
				auto err = cast(Error) e;
				Exception* pe = &e;
				const(Exception*) cpe = &e;
				throw new Error("unexpected");
			}
			finally
			{
				x = 0;
			}
			return null;
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  9,  20, "(local variable) `object.Exception e`");
	checkTip(m,  9,  10, "(class) `object.Exception`");
	checkTip(m,  11, 21, "(class) `object.Error`");
	checkTip(m,  12,  5, "(class) `object.Exception`");
	checkTip(m,  13, 11, "(class) `object.Exception`");
	checkTip(m,   2,  9, "(class) `object.Exception`");

	source =
	q{                                   // Line 1
		struct S
		{
			int field1 = 1;
			int field2 = 2;              // Line 5
			int fun(int par) { return field1 + par; }
			int more = 3;
		}
		void foo()
		{                                // Line 10
			S anS;
			int x = anS.f(1);
			int y = anS.
		}
	};
	m = checkErrors(source,
		"14,2,14,3:Error: identifier or `new` expected following `.`, not `}`\n" ~
		"14,2,14,3:Error: semicolon expected, not `}`\n" ~
		"12,14,12,15:Error: no property `f` for type `S`\n");
	//dumpAST(m);
	checkExpansions(m, 12, 16, "f", [ "field1", "field2", "fun" ]);
	checkExpansions(m, 13, 16, "", [ "field1", "field2", "fun", "more" ]);
	checkExpansions(m, 13, 13, "an", [ "anS" ]);

	source =
	q{                                   // Line 1
		struct S
		{
			int fun(int par) { return par; }
		}                                // Line 5
		void fun(int rec)
		{
			S anS;
			int x = anS.fun(1);
			if (rec)                     // Line 10
				fun(false);
		}
	};
	m = checkErrors(source, "");

	IdTypePos[][string] exp = [
		"S":   [ IdTypePos(TypeReferenceKind.Struct) ],
		"x":   [ IdTypePos(TypeReferenceKind.LocalVariable) ],
		"anS": [ IdTypePos(TypeReferenceKind.LocalVariable) ],
		"rec": [ IdTypePos(TypeReferenceKind.ParameterVariable) ],
		"par": [ IdTypePos(TypeReferenceKind.ParameterVariable) ],
		"fun": [ IdTypePos(TypeReferenceKind.Method),
		         IdTypePos(TypeReferenceKind.Function, 6, 8),
		         IdTypePos(TypeReferenceKind.Method, 9, 16),
		         IdTypePos(TypeReferenceKind.Function, 11, 5)],
	];
	checkIdentifierTypes(m, exp);

	// references
	source =
	q{                                   // Line 1
		struct S
		{
			int fun(int par) { return par; }
			int foo() { return fun(1); } // Line 5
		}
		void fun(int rec)
		{
			S anS;
			int x = anS.fun(1);          // Line 10
			if (rec) fun(false);
		}
	};
	m = checkErrors(source, "");

	checkReferences(m, 4, 8, [TextPos(4,8), TextPos(5, 23), TextPos(10, 16)]); // fun

	// foreach lowered to for
	source = q{                          // Line 1
		import std.range;
		int fun(int rec)
		{
			int sum = 0;                 // Line 5
			foreach(i; iota(0, rec))
				sum += i;
			return sum;
		}
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m, 6, 12, "(local variable) `int i`");
	checkTip(m, 7, 5, "(local variable) `int sum`");
	checkTip(m, 7, 12, "(local variable) `int i`");

	source = q{                          // Line 1
		enum TOK : ubyte
		{
			reserved,
			leftParentheses,             // Line 5
			rightParentheses, /// right parent doc
		}
		void foo(TOK op)
		{
			if (op == TOK.leftParentheses) {}   // Line 10
		}
		class Base : Object
		{
			this(TOK op, size_t sz) {}
		}                                // Line 15
		/// right base doc
		class RightBase : Base
		{
			this()
			{                            // Line 20
				super(TOK.rightParentheses, RightBase.sizeof);
			}
		}
		TOK[Base] mapBaseTOK;

		c_long testcase(int op)
		{
			switch(op)
			{   // from object.d
				case TypeInfo_Class.ClassFlags.isCOMclass:       // Line 30
				case TypeInfo_Class.ClassFlags.noPointers:
				default:
					break;
			}
			return 0;
		}
		import core.stdc.config;
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m, 10,  8, "(parameter) `source.TOK op`");
	checkTip(m, 10, 14, "(enum) `source.TOK`");
	checkTip(m, 10, 18, "(enum value) `source.TOK.leftParentheses = 1`");
	checkTip(m, 21, 11, "(enum) `source.TOK`");
	checkTip(m, 21, 15, "(enum value) `source.TOK.rightParentheses = 2`");
	checkTip(m, 21, 33, "(class) `source.RightBase`\n\nright base doc");
	checkTip(m, 24, 19, "(thread local variable) `source.TOK[source.Base] source.mapBaseTOK`");
	checkTip(m, 24,  7, "(class) `source.Base`");
	checkTip(m, 24,  3, "(enum) `source.TOK`");
	checkTip(m, 30, 10, "(class) `object.TypeInfo_Class`");
	checkTip(m, 30, 25, "(enum) `object.TypeInfo_Class.ClassFlags`");
	checkTip(m, 30, 36, "(enum value) `object.TypeInfo_Class.ClassFlags.isCOMclass = 1u`");
	checkTip(m, 21, 43, "(constant) `ulong source.RightBase.sizeof = 8LU`");

	IdTypePos[][string] exp2 = [
		"size_t":           [ IdTypePos(TypeReferenceKind.BasicType) ],
		"Base":             [ IdTypePos(TypeReferenceKind.Class) ],
		"mapBaseTOK":       [ IdTypePos(TypeReferenceKind.TLSVariable) ],
		"TOK":              [ IdTypePos(TypeReferenceKind.Enum) ],
		"testcase":         [ IdTypePos(TypeReferenceKind.Function) ],
		"rightParentheses": [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"__ctor":           [ IdTypePos(TypeReferenceKind.Method) ],
		"sz":               [ IdTypePos(TypeReferenceKind.ParameterVariable) ],
		"RightBase":        [ IdTypePos(TypeReferenceKind.Class) ],
		"foo":              [ IdTypePos(TypeReferenceKind.Function) ],
		"leftParentheses":  [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"op":               [ IdTypePos(TypeReferenceKind.ParameterVariable) ],
		"reserved":         [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"noPointers":       [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"isCOMclass":       [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"TypeInfo_Class":   [ IdTypePos(TypeReferenceKind.Class) ],
		"ClassFlags":       [ IdTypePos(TypeReferenceKind.Enum) ],
		"Object":           [ IdTypePos(TypeReferenceKind.Class) ],
		"core":             [ IdTypePos(TypeReferenceKind.Package) ],
		"stdc":             [ IdTypePos(TypeReferenceKind.Package) ],
		"config":           [ IdTypePos(TypeReferenceKind.Module) ],
		"c_long":           [ IdTypePos(TypeReferenceKind.BasicType) ],
		"sizeof":           [ IdTypePos(TypeReferenceKind.Constant) ],
	];
	checkIdentifierTypes(m, exp2);

	source = q{
		void fun()
		{
			string cmd = "cmd";
			bool isX86_64 = true;        // Line 5
			cmd = "pushd .\n" ~ `call vcvarsall.bat ` ~ (isX86_64 ? "amd64" : "x86") ~ "\n" ~ "popd\n" ~ cmd;
		}
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m,  6, 49, "(local variable) `bool isX86_64`");
	checkTip(m,  6, 97, "(local variable) `string cmd`");

	source = q{
		int fun()
		{
			int sum;
			foreach(m; object.ModuleInfo)  // Line 5
				if (m) sum++;
			return sum;
		}
	};
	m = checkErrors(source, "");
	//dumpAST(m);
	checkTip(m,  6,  9, "(foreach variable) `object.ModuleInfo* m`");
	checkTip(m,  5, 12, "(foreach variable) `object.ModuleInfo* m`");
	checkTip(m,  5, 15, "(module) `object`");
	checkTip(m,  5, 22, "(struct) `object.ModuleInfo`");

	exp2 = [
		"fun":              [ IdTypePos(TypeReferenceKind.Function) ],
		"sum":              [ IdTypePos(TypeReferenceKind.LocalVariable) ],
		"m":                [ IdTypePos(TypeReferenceKind.ParameterVariable) ],
		"object":           [ IdTypePos(TypeReferenceKind.Module) ],
		"ModuleInfo":       [ IdTypePos(TypeReferenceKind.Struct) ],
	];
	checkIdentifierTypes(m, exp2);

	source = q{
		void fun()
		{
			string str = "hello";
			string cmd = ()     // Line 5
			{
				auto local = str.length;
				return str;
			}();
		}
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m,  7, 10, "(local variable) `ulong local`");
	checkTip(m,  7, 18, "(local variable) `string str`");

	source = q{
		struct S(T)
		{
			T member;
		}                              // Line 5
		S!int x;
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m,  6,  9, "(thread local variable) `source.S!int source.x`");
	checkTip(m,  4,  6, "(field) `int source.S!int.member`");
	checkTip(m,  6,  3, "(struct) `source.S!int`");

	// check for conditional not producing warning "unreachable code"
	source = q{
		void foo()
		{
			version(none)
			{                          // Line 5
			}
			int test;
		}
	};
	m = checkErrors(source, "");

	// check for semantics in unittest
	source = q{
		unittest
		{
			int var1 = 1;
			int var2 = var1 + 1;       // Line 5
		}
	};
	m = checkErrors(source, "");
	checkTip(m,  5, 15, "(local variable) `int var1`");

	// check position of var in AddrExp
	source = q{
		void fun(int* p);
		void foo()
		{
			int var = 1;               // Line 5
			fun(&var);
		}
	};
	m = checkErrors(source, "");
	checkReferences(m, 5, 8, [TextPos(5,8), TextPos(6, 9)]); // var

	// check position of var in AddrExp
	source = q{
		struct S { int x = 3; }
		void fun(T)(T* p) {}
		void foo()
		{
			S var;               // Line 6
			fun!(S)(&var);
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  7,  9, "(struct) `source.S`");

	// check template arguments
	source = q{
		void fun(T)() {}
		void foo()
		{
			fun!(object.ModuleInfo)();  // Line 5
		}
	};
	m = checkErrors(source, "");

	checkTip(m,  5,  9, "(module) `object`");
	checkTip(m,  5, 16, "(struct) `object.ModuleInfo`");

	exp2 = [
		"fun":              [ IdTypePos(TypeReferenceKind.Function) ],
		"foo":              [ IdTypePos(TypeReferenceKind.Function) ],
		"object":           [ IdTypePos(TypeReferenceKind.Module) ],
		"ModuleInfo":       [ IdTypePos(TypeReferenceKind.Struct) ],
	];
	checkIdentifierTypes(m, exp2);

	// check FQN types in cast
	source = q{
		void foo()
		{
			auto e = cast(object.Exception) null;
			auto p = cast(object.Exception*) null;  // Line 5
		}
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m,  4, 18, "(module) `object`");
	checkTip(m,  4, 25, "(class) `object.Exception`");
	checkTip(m,  5, 18, "(module) `object`");
	checkTip(m,  5, 25, "(class) `object.Exception`");

	exp2 = [
		"foo":       [ IdTypePos(TypeReferenceKind.Function) ],
		"object":    [ IdTypePos(TypeReferenceKind.Module) ],
		"Exception": [ IdTypePos(TypeReferenceKind.Class) ],
		"e":         [ IdTypePos(TypeReferenceKind.LocalVariable) ],
		"p":         [ IdTypePos(TypeReferenceKind.LocalVariable) ],
	];
	checkIdentifierTypes(m, exp2);

	// fqn, function call on static members
	source = q{
		struct Mem
		{
			static Mem foo(int sz) { return Mem(); }
		}                                    // Line 5
		__gshared Mem mem;
		void fun()
		{
			source.Mem m = source.mem.foo(1234);
		}                                    // Line 10
	};
	m = checkErrors(source, "");
	//dumpAST(m);

	checkTip(m,  9, 30, "`Mem source.Mem.foo(int sz)`");
	checkTip(m,  9, 19, "(module) `source`");
	checkTip(m,  9, 26, "(__gshared variable) `source.Mem source.mem`");
	checkTip(m,  9, 11, "(struct) `source.Mem`");
	checkTip(m,  9,  4, "(module) `source`");

	///////////////////////////////////////////////////////////
	// check array initializer
	filename = "tok.d";
	source = q{
		module tok;
		enum TOK : ubyte
		{
			reserved,

			// Other
			leftParentheses,
			rightParentheses,
			max_
		}
		enum PREC : int
		{
			zero,
			expr,
		}
	};
	m = checkErrors(source, "");
	source = q{
		import tok;
		immutable PREC[TOK.max_] precedence =
		[
			TOK.reserved : PREC.zero,             // Line 5
			TOK.leftParentheses : PREC.expr,
		];
	};
	filename = "source.d";
	m = checkErrors(source, "");

	// TODO: checkTip(m, 3, 18, "(enum) `tok.TOK`");
	checkTip(m, 3, 22, "(enum value) `tok.TOK.max_ = 3`");
	checkTip(m, 3, 13, "(enum) `tok.PREC`");
	checkTip(m, 5,  4, "(enum) `tok.TOK`");
	checkTip(m, 5,  8, "(enum value) `tok.TOK.reserved = cast(ubyte)0u`");
	checkTip(m, 5, 19, "(enum) `tok.PREC`");
	checkTip(m, 5, 24, "(enum value) `tok.PREC.zero = 0`");

	IdTypePos[][string] exp4 = [
		"tok":             [ IdTypePos(TypeReferenceKind.Package) ],
		"zero":            [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"expr":            [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"reserved":        [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"leftParentheses": [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"max_":            [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"PREC":            [ IdTypePos(TypeReferenceKind.Enum) ],
		"TOK":             [ IdTypePos(TypeReferenceKind.Enum) ],
		"precedence":      [ IdTypePos(TypeReferenceKind.GSharedVariable) ],
	];
	checkIdentifierTypes(m, exp4);

	source = q{
		int[] darr = [ TypeInfo_Class.ClassFlags.isCOMclass ];
		int[int] aarr =
		[
			TypeInfo_Class.ClassFlags.isCOMclass : 1,  // Line 5
			1 : TypeInfo_Class.ClassFlags.isCOMclass
		];
		int[] iarr = [ TypeInfo_Class.ClassFlags.noPointers : 1 ];
		void fun()
		{                                              // Line 10
			auto a = darr.length + aarr.length;
			auto p = darr.ptr;
		}
	};
	m = checkErrors(source, "");
	checkTip(m,  2, 18, "(class) `object.TypeInfo_Class`");
	checkTip(m,  2, 33, "(enum) `object.TypeInfo_Class.ClassFlags`");
	checkTip(m,  2, 44, "(enum value) `object.TypeInfo_Class.ClassFlags.isCOMclass = 1u`");
	checkTip(m,  5, 4, "(class) `object.TypeInfo_Class`");
	checkTip(m,  5, 19, "(enum) `object.TypeInfo_Class.ClassFlags`");
	checkTip(m,  5, 30, "(enum value) `object.TypeInfo_Class.ClassFlags.isCOMclass = 1u`");
	checkTip(m,  6, 8, "(class) `object.TypeInfo_Class`");
	checkTip(m,  6, 23, "(enum) `object.TypeInfo_Class.ClassFlags`");
	checkTip(m,  6, 34, "(enum value) `object.TypeInfo_Class.ClassFlags.isCOMclass = 1u`");
	checkTip(m,  8, 18, "(class) `object.TypeInfo_Class`");
	checkTip(m,  8, 33, "(enum) `object.TypeInfo_Class.ClassFlags`");
	checkTip(m,  8, 44, "(enum value) `object.TypeInfo_Class.ClassFlags.noPointers = 2u`");
	checkTip(m, 11, 18, "(field) `ulong int[].length`");
	checkTip(m, 11, 32, "(field) `ulong int[int].length`");
	checkTip(m, 12, 18, "(field) `int* int[].ptr`");

	checkReferences(m, 2, 44, [TextPos(2,44), TextPos(5, 30), TextPos(6, 34)]); // isCOMclass

	IdTypePos[][string] exp3 = [
		"isCOMclass":       [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"noPointers":       [ IdTypePos(TypeReferenceKind.EnumValue) ],
		"TypeInfo_Class":   [ IdTypePos(TypeReferenceKind.Class) ],
		"ClassFlags":       [ IdTypePos(TypeReferenceKind.Enum) ],
		"darr":             [ IdTypePos(TypeReferenceKind.TLSVariable) ],
		"aarr":             [ IdTypePos(TypeReferenceKind.TLSVariable) ],
		"iarr":             [ IdTypePos(TypeReferenceKind.TLSVariable) ],
		"fun":              [ IdTypePos(TypeReferenceKind.Function) ],
		"length":           [ IdTypePos(TypeReferenceKind.MemberVariable) ],
		"ptr":              [ IdTypePos(TypeReferenceKind.MemberVariable) ],
		"a":                [ IdTypePos(TypeReferenceKind.LocalVariable) ],
		"p":                [ IdTypePos(TypeReferenceKind.LocalVariable) ],
	];
	checkIdentifierTypes(m, exp3);

	// more than 7 cases translated to table
	source = q{
		bool isReserved(const(char)[] ident)
		{
			// more than 7 cases use dup
			switch (ident)
			{
				case "DigitalMars":
				case "GNU":
				case "LDC":
				case "SDC":
				case "Windows":
				case "Win32":
				case "Win64":
				case "linux":
				case "OSX":
				case "iOS":
				case "TVOS":
				case "WatchOS":
				case "FreeBSD":
				case "OpenBSD":
				case "NetBSD":
				case "DragonFlyBSD":
				case "BSD":
				case "Solaris":
					return true;
				default:
					return false;
			}
		}
	};
	m = checkErrors(source, "");

	// change settings to restart everything
	opts.unittestOn = false;
	filename = "source2.d";
	m = checkErrors(source, "");

	// can object.d create reserved classes, e.g. Error?
	source = q{
		module object;
		alias ulong size_t;
		class Object
		{
		}
		class Throwable
		{
		}
		class Error : Throwable
		{
		}
	};
	m = checkErrors(source, "");
	// beware: bad object.d after this point
	lastContext = null;
}

unittest
{
	import core.memory;
	import std.path;
	import std.file;

	dmdInit();

	string srcdir = "dmd/src";

	Options opts;
	opts.predefineDefaultVersions = true;
	opts.x64 = true;
	opts.msvcrt = true;
	opts.warnings = true;
	opts.importDirs = guessImportPaths() ~ srcdir;
	opts.stringImportDirs ~= srcdir ~ "/../res";
	opts.versionIds ~= "MARS";
	//opts.versionIds ~= "NoBackend";

	auto filename = std.path.buildPath(srcdir, "dmd/expressionsem.d");

	static void assert_equal(S, T)(S s, T t)
	{
		if (s == t)
			return;
		assert(false);
	}

	Module checkErrors(string src, string expected_err)
	{
		try
		{
			initErrorMessages(filename);
			Module parsedModule = createModuleFromText(filename, src);
			assert(parsedModule);
			Module m = analyzeModule(parsedModule, opts);
			auto err = getErrorMessages();
			auto other = getErrorMessages(true);
			assert_equal(err, expected_err);
			assert_equal(other, "");
			return m;
		}
		catch(Throwable t)
		{
			throw t;
		}
	}
	string source = cast(string)std.file.read(filename);
	Module m = checkErrors(source, "");
}

// https://issues.dlang.org/show_bug.cgi?id=20253
enum TTT = 9;
void dummy()
{
	import std.file;
	std.file.read(""); // no tip on std and file
	auto x = TTT;
	int[] arr;
	auto s = arr.ptr;
	auto y = arr.length;
	auto my = arr.mangleof;
	auto zi = size_t.init;
	auto z0 = size_t.min;
	auto z1 = size_t.max;
	auto z2 = size_t.alignof;
	auto z3 = size_t.stringof;
	float flt;
	auto q = [flt.sizeof, flt.init, flt.epsilon, flt.mant_dig, flt.infinity, flt.re, flt.min_normal, flt.min_10_exp];
	auto ti = Object.classinfo;
}

struct XMem
{
	static XMem foo(int sz) { return XMem(); }
}
__gshared XMem xmem;

template Templ(T)
{
	struct Templ
	{
		T payload;
	}
}
void fun()
{
	Templ!(XMem) arr;
	vdc.dmdserver.semanalysis.XMem m = vdc.dmdserver.semanalysis.xmem.foo(1234);
}
