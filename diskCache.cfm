<!---
cf_diskCache

A file-based caching mechanism to enhance performance of managed content

Caching of content is based on URL; wrap tag call around contents to cache.
<cf_diskCache>{content}</cf_diskCache>
	No required attributes.
	Optional attributes:
	directory - an absolute path to a cache directory
	timespan - age in days of expiration, use #CreateTimeSpan(d,h,m,s)#

Flushing clears the entire cache specified. call as empty tag, self-closing tag, or start/end tags.
<cf_diskCache flushcache="true" directory="#somedirectory#"/>
	Required attributes:
	flushcache - must evaluate to true in order to flush the cache. other values prevent caching from operation in any sense
	directory - an absolute path to a cache directory

--->
<!---
Copyright 2009 choop

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 --->

<!--- are we flushing? verify, attempt, and exit. both flushing and caching content never occurs in the same call --->
<cfif StructKeyExists(attributes, 'flushcache')>
	<!--- check value in a separate if statement to allow dynamic flushing --->
	<cfif attributes.flushcache>
		<!--- validate that a cache directory is specified --->
		<cfif NOT StructKeyExists(attributes, 'directory')>
			<cfthrow type="CustomTagValidation" detail="When flushing a cache, you must specify a cache folder."/>
		</cfif>
		<cfset cacheToClear = diskcache___directoryListing(attributes.directory)/>
		<cfset cacheToClear = diskcache___filterQuery(cacheToClear, "name", "%.cache.html")/>
		<cfloop query="cacheToClear">
			<cffile action="delete" file="#attributes.directory#/#name#"/>
		</cfloop>
	</cfif>
	<!--- we are flushing. never attempt to cache content. --->
	<cfexit method="exittag"/>
<cfelseif NOT ThisTag.HasEndTag>
	<!--- error, cannot cache content without both start and end tags --->
	<cfthrow type="CustomTagValidation" detail="Unless flushing a cache, you must provide both a start tag and an end tag."/>
</cfif>

<!--- never cache form method="post" requests. --->
<cfif NOT StructKeyExists(cgi, 'request_method') OR cgi.request_method NEQ "get">
	<cfexit method="exittemplate"/>
</cfif>

<!--- how old a file may be retrieved? default to three years --->
<cfif NOT StructKeyExists(attributes, 'timespan')>
	<cfset attributes.timespan = 1095/><!--- number of days in three years --->
</cfif>
<cfset attributes.timespan = 86400 * attributes.timespan/><!--- number of seconds in a day --->

<!--- if no cache folder specified, use the base path as the cache folder --->
<cfif NOT StructKeyExists(attributes, 'directory')>
	<cfset attributes.directory = ExpandPath(ListDeleteAt(cgi.path_translated, ListLen(cgi.path_translated, '\/'), '\/'))/>
</cfif>

<!--- generate name of cached file --->
<cfset filename = ListFirst(ListLast(cgi.path_translated, '\/'), '.') & '_'/>
<cfif StructKeyExists(request, "cacheOverride") AND request.cacheOverride EQ "skip query string">
	<cfset filename = filename & Hash(cgi.script_name)/>
<cfelse>
	<!--- construct querystring in case the url scope has been altered - use the altered url, not the raw cgi.query_string --->
	<cfset keys = ListSort(StructKeyList(url), "text", "asc")/>
	<cfset querystring = ""/>
	<cfloop list="#keys#" index="key">
		<cfset querystring = querystring & key & "=" & url[key]/>
	</cfloop>
	<cfset filename = filename & Hash(cgi.script_name & querystring)/>
</cfif>
<cfset filename = filename & '.cache.html'/>

<!--- has file already been cached? --->
<cfif FileExists(attributes.directory & '/' & filename)>
	<!--- get cached file information --->
	<cfset checkFile = diskcache___fileInfo(attributes.directory & '/' & filename)>
	<!--- if the cached version is not too old, output its contents and skip to the end of the tag call to avoid processing --->
	<cfif ThisTag.ExecutionMode EQ 'start' AND Val(attributes.timespan) GT 0 AND Abs(DateDiff("s", now(), checkFile.modified)) LT attributes.timespan>
		<cffile action="read" file="#attributes.directory#/#filename#" variable="cachedcontent"/>
		<!--- <cfsetting showdebugoutput="false"/> --->
		<cfcontent reset="true"/><!---
		---><cfoutput>#cachedcontent#</cfoutput>
		<cfexit method="exittag"/>
	</cfif>
	<!--- if the cached version is too old, delete it and allow the content to be generated for caching later --->
	<cfif Val(attributes.timespan) GT 0 AND Abs(DateDiff("s", now(), checkFile.modified)) GT attributes.timespan>
		<cffile action="delete" file="#attributes.directory#/#filename#"/>
	</cfif>
</cfif>
<cfsetting requesttimeout="60"/>

<!--- if the page is not yet cached, verify that it is allowed to be. generic exception to caching engine provided to allow business rules to override engine --->
<cfparam name="request.cacheRequest" default="true"/>
<cfif request.cacheRequest AND ThisTag.ExecutionMode EQ 'end' AND NOT FileExists(attributes.directory & '/' & filename)>
	<cfparam name="request.cacheRequest" default="true"/>
	<!--- store file --->
	<cffile action="write" file="#attributes.directory#/#filename#" attributes="normal"
			 output="#Trim(REReplace(ThisTag.GeneratedContent, '\s+', ' ', 'ALL'))##chr(13)##chr(10)#<!-- cached page generated #Now()# -->#chr(13)##chr(10)#" />
</cfif>

<!--- utility functions used above --->

<cffunction name="diskcache___filterQuery" returntype="query" output="false">
	<cfargument name="incoming" type="query" required="true"/>
	<cfargument name="column" type="string" required="true"/>
	<cfargument name="filter" type="string" default=""/>
	<cfset var outgoing = ""/>
	<cfquery name="outgoing" dbtype="query">
		select * from arguments.incoming where column like '%#arguments.filter#%'
	</cfquery>
	<cfreturn outgoing/>
</cffunction>

<!--- Thanks to Anuj Gakhar, Dan Wilson, Mark Kruger, and Ryan Stille for this function and code in the next; no attribution info provided --->
<cffunction name="diskcache___directoryListing" returntype="query" output="false">
	<cfargument name="pathToparse" type="string" required="true" hint="Absolute path as string"/>
	<cfargument name="recurse" type="boolean" default="false" required="false" hint="Continue down subdirectories?"/>
	<cfargument name="dirInfo" type="query" default="#queryNew('name,type,modified')#" hint="Results query to append to, or ignore."/>

	<cfset var thisFile = "" />
	<cfset var listFiles = "" />
	<cfset var fileObj = createObject("java","java.io.File")/>
	<cfset var info = ""/>

	<cfif Len(arguments.pathToparse)>
		<cfset listFiles = fileObj.init(Trim(arguments.pathToParse)).list()/>
		<cfloop from="1" to="#arraylen(listFiles)#" index="thisFile">
			<cfset queryAddRow(arguments.dirInfo)>
			<cfset querySetCell(arguments.dirInfo, "name", listFiles[thisFile])/>
			<cfset info = diskcache___fileInfo(arguments.pathToParse & listFiles[thisFile])>
			<cfset QuerySetCell(arguments.dirInfo, "modified", info.modified)/>
			<cfif info.isDir>
				<cfset querySetCell(arguments.dirInfo,"type","dir")/>
				<cfif arguments.recurse>
					<cfset DirectoryListing(arguments.pathToParse & listFiles[thisFile], arguments.recurse, arguments.dirInfo)/>
				</cfif>
			<cfelse>
				<cfset querySetCell(arguments.dirInfo,"type","file")/>
			</cfif>
		</cfloop>
		<cfquery name="arguments.dirInfo" dbtype="query">
			SELECT name,type, upper(name) as uppername
			FROM arguments.dirInfo
			ORDER BY Type asc, uppername asc
		</cfquery>
	</cfif>
	<cfreturn arguments.dirInfo/>
</cffunction>

<cffunction name="diskcache___fileInfo" returntype="struct" output="false">
	<cfargument name="filepath" type="string" required="true" hint="Absolute path to file"/>
	<cfscript>
		var fileObj = createObject("java", "java.io.File").init(arguments.filepath);
		var info = StructNew();
		info.hidden = fileObj.isHidden();
		info.modified = DateAdd("s", fileObj.lastModified()/1000, CreateDateTime(1970, 1, 1, 0, 0, 0));
		info.size = Val(fileObj.length());
		info.isDir = fileObj.isDirectory();
		return info;
	</cfscript>
</cffunction>
