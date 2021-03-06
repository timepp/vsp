import std.stdio;
import std.string;
import std.array;
import std.getopt;
import std.file;
import std.path;
import std.xml;
import std.uuid;
import std.regex;
import std.process;
import std.exception;
import std.algorithm;
import std.experimental.logger;
import wind.string;

/**
    Although it's called "filter" in visual studio, the same file cannot belong to different filters.
    
    In vcxproj:
    ItemGroup:
        ClCompile/ClInclude/None/ResourceCompile/Manifest/Image
        
    In vcxproj.filters:
    <ItemGroup>
        <Filter Include="tps">
            <UniqueIdentifier>{d38c671a-5665-4487-9e43-0ebe159dd8a4}</UniqueIdentifier>
        </Filter>
        <Filter Include="tps\aaa">
            <UniqueIdentifier>{248cee31-14ad-4ddb-aab3-e0d3a3e8a6af}</UniqueIdentifier>
        </Filter>
    </ItemGroup>
*/   

string rootDir;
bool testMode = false;

struct VisualStudioItem
{
    string relativePath;
    string absolutePath;
    string type;
    string filter;
};

void nicerGetoptPrinter(string text, Option[] opt)
{
    import std.stdio : stdout;
    nicerGetoptFormatter(stdout.lockingTextWriter(), text, opt);
}

void nicerGetoptFormatter(Output)(Output output, string text, Option[] opt)
{
    import std.format : formattedWrite; 
    import std.algorithm : min, max; 

    output.formattedWrite("%s\n", text); 

    size_t ls, ll; 
    bool hasRequired = false; 
    foreach (it; opt) 
    { 
        ls = max(ls, it.optShort.length); 
        ll = max(ll, it.optLong.length); 

        hasRequired = hasRequired || it.required; 
    } 

    string re = " Required: ";

    size_t prefixLength = ls + 1 + ll + (hasRequired? re.length : 1);

    foreach (it; opt) 
    {
        string[] lines = it.help.split("\n");
        foreach(i,l; lines)
        {
            if (i == 0)
                output.formattedWrite("%*s %*s%*s%s\n", ls, it.optShort, ll, it.optLong, 
                                      hasRequired ? re.length : 1, it.required ? re : " ", l);
            else
                output.formattedWrite("%*s%s\n", prefixLength, " ", l);
        }
    } 
   
}

string GetVisualStudioDefaultTypeByFileExtension(string ext)
{
    switch (ext.toLower())
    {
    case ".c":
    case ".cc":
    case ".cpp":
    case ".cxx":
        return "ClCompile";

    case ".h":
    case ".hh":
    case ".hxx":
    case ".tmh":
        return "ClInclude";

    case ".rc":
        return "ResourceCompile";

    case ".png":
    case ".jpg":
    case ".bmp":
    case ".jpeg":
        return "Image";

    default:
        break;
    }
    return "None";
}

string[] possibleFilters(string filter)
{
    string[] ret;
    string[] components = filter.split("\\");
    foreach(i; 0..components.length)
    {
        ret ~= components[0..i+1].join("\\");
    }
    return ret;
}

unittest
{
    assert(possibleFilters("aaa\\bbb\\ccc\\ddd") ==
           [
               "aaa",
               "aaa\\bbb",
               "aaa\\bbb\\ccc",
               "aaa\\bbb\\ccc\\ddd"
           ]
           );
}

void AddFilesToVisualStudioProject(VisualStudioItem[] items, string filename, bool withFilterInformation)
{
    string s = cast(string)std.file.read(filename);
    auto doc = new Document(s);

    bool[string] existingFiles;
    Element[string] specialElements;
    bool itemRemoved = false;
    // Find correct Elements
    foreach (ref Element e; doc.elements)
    {
        if (e.tag.name == "ItemGroup")
        {
            string elemType;
            if (e.elements.length > 0)
            {
                elemType = e.elements[0].tag.name;
            }

            if (elemType.length > 0)
            {
                specialElements[elemType] = e;
            }

            if (elemType != "ProjectConfiguration" && elemType != "Filter")
            {
                for (auto i = 0; i < e.items.length; )
                {
                    Element fileNode = cast(Element) e.items[i];
                    if (fileNode !is null && "Include" in fileNode.tag.attr)
                    {
                        string relaPath = fileNode.tag.attr["Include"];
                        string path = std.path.buildNormalizedPath(std.path.dirName(filename), fileNode.tag.attr["Include"]);
                        if (indexOf(relaPath, '$') == -1 && !exists(path))
                        {
                            e.items = remove(e.items, i);
                            itemRemoved = true;
                            writeln("warning: file no longer exists. removed: ", relaPath);
                        }
                        else
                        {
                            existingFiles[path.toLower()] = true;
                            i++;
                        }
                    }
                    else
                    {
                        i++;
                    }
                }
            }
        }
    }

    trace("existing files: ", existingFiles);
    trace("items: ", items);

    VisualStudioItem[] pendingAddItems;

    bool[string] filtermap;
    foreach (VisualStudioItem item; items)
    {
        if (item.absolutePath.toLower() in existingFiles)
        {
            trace("file already exsits in project: ", item.relativePath);
            continue;
        }

        pendingAddItems ~= item;
    }

    foreach (VisualStudioItem item; pendingAddItems)
    {
        writeln("add: ", item.relativePath);
        
        Element groupNode;
        if (item.type in specialElements)
        {
            groupNode = specialElements[item.type];
        }
        else
        {
            groupNode = new Element("ItemGroup");
            specialElements[item.type] = groupNode;
            doc ~= groupNode;
        }

        Element node = new Element(item.type);
        node.tag.attr["Include"] = item.relativePath;

        if (withFilterInformation && item.filter.length > 0)
        {
            node ~= new Element("Filter", item.filter);

            Element filtersNode;
            if ("Filter" in specialElements)
            {
                filtersNode = specialElements["Filter"];
                foreach (Element e; filtersNode.elements)
                {
                    filtermap[e.tag.attr["Include"]] = true;
                }
            }
            else
            {
                filtersNode = new Element("ItemGroup");
                specialElements["Filter"] = filtersNode;
                doc ~= filtersNode;
            }

            foreach(string filter; possibleFilters(item.filter))
            {
                if (filter !in filtermap)
                {
                    filtermap[filter] = true;
                    Element filterNode = new Element("Filter");
                    filterNode.tag.attr["Include"] = filter;
                    Element uuidNode = new Element("UniqueIdentifier", "{" ~ randomUUID().toString() ~ "}");
                    filterNode ~= uuidNode;
                    filtersNode ~= filterNode;
                }
            }
        }

        groupNode ~= node;
    }

    if (pendingAddItems.length == 0 && !itemRemoved)
    {
        writeln("there is no new item to add or remove.");
        return;
    }

    string content = doc.prolog ~ join(doc.pretty(2), "\r\n") ~ doc.epilog;

    if (testMode)
    {
        writeln("new content in file: " ~ filename);
        writeln("=========================================================================================");
        writeln(content);
        writeln("=========================================================================================");
        writeln("=========================================================================================");
    }
    else
    {
        std.file.copy(filename, filename ~ ".bak");
        std.file.write(filename, content);
    }
}

bool hasSameRoot(string dir1, string dir2)
{
    return relativePath(dir1, dir2) != dir1;
}

bool isSubDir(string dir1, string dir2)
{
    string str = relativePath(dir1, dir2);
    return str != dir1 && !str.startsWith("..");
}

string emptyFilterFileContent = `<?xml version="1.0" encoding="utf-8"?>
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003" ToolsVersion="4.0">
</Project>
`;

string projectFileTemplate = `<?xml version="1.0" encoding="utf-8"?>
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003" DefaultTargets="Build" ToolsVersion="12.0">
  <ItemGroup Label="ProjectConfigurations">
    <ProjectConfiguration Include="Debug|Win32">
      <Configuration>Debug</Configuration>
      <Platform>Win32</Platform>
    </ProjectConfiguration>
    <ProjectConfiguration Include="Debug|x64">
      <Configuration>Debug</Configuration>
      <Platform>x64</Platform>
    </ProjectConfiguration>
  </ItemGroup>
  <PropertyGroup Label="Globals">
    <ProjectGuid>{EEC344A0-08BE-48FE-A1FD-43E1135266C8}</ProjectGuid>
    <RootNamespace>$(NAME)</RootNamespace>
    <ProjectName>$(NAME)</ProjectName>
  </PropertyGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Default.props" />
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.props" />
  <ImportGroup Label="PropertySheets" Condition="'$(Configuration)|$(Platform)'=='Debug|Win32'">
    <Import Label="LocalAppDataPlatform" Project="$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props" Condition="exists('$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props')" />
  </ImportGroup>
  <ImportGroup Condition="'$(Configuration)|$(Platform)'=='Debug|x64'" Label="PropertySheets">
    <Import Project="$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props" Condition="exists('$(UserRootDir)\Microsoft.Cpp.$(Platform).user.props')" Label="LocalAppDataPlatform" />
  </ImportGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Debug|Win32'">
    <ClCompile>
      <PreprocessorDefinitions>WIN32;_DEBUG;_WINDOWS;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
  </ItemDefinitionGroup>
  <ItemDefinitionGroup Condition="'$(Configuration)|$(Platform)'=='Debug|x64'">
    <ClCompile>
      <PreprocessorDefinitions>WIN32;_DEBUG;_WINDOWS;%(PreprocessorDefinitions)</PreprocessorDefinitions>
    </ClCompile>
  </ItemDefinitionGroup>
  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.targets" />
</Project>
`;

LogLevel StringLogLevelToLogLevel(string lvl)
{
    switch (lvl.toLower())
    {
        case "trace": return LogLevel.trace;
        case "info": return LogLevel.info;
        case "warning": return LogLevel.warning;
        case "error": return LogLevel.error;
        case "critical": return LogLevel.critical;
        case "fatal": return LogLevel.fatal;
        default: return LogLevel.warning;
    }
}

void printGeneralUsage()
{
    string usage = `
        usage: vsp <command> [command arguments]

        supported command:
            add

        type:
            vsp <command> --help
        for detailed help of specific commands. `.unindent();

    writeln(usage);
}

void main(string[] argv)
{
    if (argv.length >= 2)
    {
        switch(argv[1])
        {
        case "add":
            return vspadd(argv[1..$]);
        default:
            break;
        }
    }

    printGeneralUsage();
}

void vspadd(string[] argv)
{
    string helpmsg = `
        recursively add all files under destdir into vs project, preserving the
        directory structure. This solves the problem that, although you can drag one 
        directory into vs project, the original directory structure will be lost.

        Include/exclude patterns can be used to filter files. exclude pattern take
        higher priority.

        By default, the filter(directory) structure for new files is relative to the
        project file. However, if a "filter prefix" is given, the filter structure
        will be relative to destdir, preceding with this filter prefix.

        By default, item paths are relative to project file. However, if the folding 
        environment variable is given, item path will instead become an absolute path.
        The path is folded by the path that the folding var points to, e.g.:
            -----------------------------------------------
            file path: c:\src\aaa.obj.amd64\bbb\ccc\ddd.cpp
            fold var:  srcroot
            fold dir:  c:\src\aaa
            -----------------------------------------------
            then item path will be: $(srcroot).obj.amd64\bbb\ccc\ddd.cpp
        This is very useful if you want to share the prject across machines/branches.
        `.unindent();

    string filterPrefix;
    string foldspec;
    string logLevel;
    string includePattern;
    string excludePattern;
    auto helpInformation = getopt(argv, 
                                  "filter-prefix|P", "Set the common filer prefix for all added items", &filterPrefix,
                                  "folding-var", "Set the folding environment variable: var[:val]", &foldspec,
                                  "include-pattern|I", "If specified, only files match(regex) the given pattern will be added", &includePattern,
                                  "exclude-pattern|E", "If specified, files match(regex) the given pattern won't be added", &excludePattern,
                                  "test", "Test mode: output result contents to console", &testMode,
                                  "loglevel", "Set log level (trace, info, warning, error, critical, fatal)", &logLevel,
                                  );
    if (helpInformation.helpWanted || argv.length != 3)
    {
        nicerGetoptPrinter("usage: vsp add [options] <projectfile> <destdir>\n", helpInformation.options);
        writeln();
        write(helpmsg);
        return;
    }

    globalLogLevel = StringLogLevelToLogLevel(logLevel);


    auto reInclude = regex(includePattern);
    auto reExclude = regex(excludePattern);
   
    string projectFileName = argv[1].absolutePath();
    string destDir = argv[2].absolutePath();
    string foldVar = splitHead(foldspec, ':');
    string foldDir = splitTail(foldspec, ':', "");
    string projectFilterFileName = projectFileName ~ ".filters";
    string projectDir = dirName(projectFileName);

    if (foldVar)
    {
        if (foldDir.length == 0)
        {
            foldDir = environment.get(foldVar);
            if (foldDir.length == 0)
            {
                writeln("cannot get folding-var value from process environment.");
                return;
            }
            foldDir = foldDir.absolutePath();
        }

        if (destDir.toLower().indexOf(foldDir.toLower()) == -1)
        {
            writeln("folding dir and dest dir must have the same root.");
            return;
        }
    }

    if (!filterPrefix)
    {
        if (!isSubDir(destDir, projectDir))
        {
            writeln("the project dir is not a parent of dest dir, please specify the fiter prefix explicitly.");
            return;
        }
        filterPrefix = relativePath(destDir, projectDir);
    }

    writeln("project:          ", projectFileName);
    writeln("project filters:  ", projectFilterFileName);
    writeln("fold variable:    ", foldVar);
    writeln("fold directory:   ", foldDir);
    writeln("dest dir:         ", destDir);
    writeln("filter prefix     ", filterPrefix);
    writeln("include pattern   ", includePattern);
    writeln("exclude pattern   ", excludePattern);
    writeln();

    if (!exists(projectFileName))
    {
        string projectFileContent = projectFileTemplate.replace("$(NAME)", baseName(projectFileName));
        std.file.write(projectFileName, projectFileContent);
        writeln("created new project file: ", projectFileName);
    }
    if (!exists(projectFilterFileName))
    {
        std.file.write(projectFilterFileName, emptyFilterFileContent);
        writeln("created new project filter file: ", projectFilterFileName);
    }

    VisualStudioItem[] items;
    // get all files
    auto files = dirEntries(destDir, SpanMode.depth);
    foreach (string f; files)
    {
        if (excludePattern.length > 0 && matchFirst(f, reExclude)) continue;
        if (includePattern.length > 0 && !matchFirst(f, reInclude)) continue;
        if (!isFile(f)) continue;
        
        trace(f);
        string relaPath = relativePath(f, destDir);
        string relaDir = dirName(relaPath);
        if (relaPath[0] == '.')
        {
            continue;
        }

        VisualStudioItem item;
        item.absolutePath = buildNormalizedPath(f);
        item.relativePath = foldVar?
            "$(%s)%s".format(foldVar, f[foldDir.length..$]):
            relativePath(f, projectDir);
        item.type = GetVisualStudioDefaultTypeByFileExtension(extension(f));

        // filterPrefix  relaDir   | item.filter
        // -------------------------------------
        // .             .         | 
        // normal        .         | normal
        // .             normal    | normal
        // normal        normal    | normal\normal
        item.filter = filterPrefix == "." ? (relaDir == "." ? "" : relaDir)
            : (relaDir == "." ? filterPrefix : filterPrefix ~ "\\" ~ relaDir); 

        items ~= item;
        trace("  ", item.type);
        trace("  ", item.filter);
        trace("  ", item.relativePath);
    }

    writeln();
    writeln("processing ", projectFileName);
    AddFilesToVisualStudioProject(items, projectFileName, false);
    writeln("done.");

    writeln();
    writeln("processing ", projectFilterFileName);
    AddFilesToVisualStudioProject(items, projectFilterFileName, true);
    writeln("done.");
}
