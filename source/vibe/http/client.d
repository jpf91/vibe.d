/**
	A simple HTTP/1.1 client implementation.

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Jan Krüger
*/
module vibe.http.client;

public import vibe.core.tcp;
public import vibe.http.common;

import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.inet.url;
import vibe.stream.zlib;

import std.array;
import std.conv;
import std.exception;
import std.format;
import std.string;


/**************************************************************************************************/
/* Public functions                                                                               */
/**************************************************************************************************/

/**
	Performs a HTTP request on the specified URL.

	The 'requester' parameter allows to customize the request and to specify the request body for
	non-GET requests.
*/
HttpClientResponse requestHttp(string url, void delegate(HttpClientRequest req) requester = null)
{
	return requestHttp(Url.parse(url), requester);
}
/// ditto
HttpClientResponse requestHttp(Url url, void delegate(HttpClientRequest req) requester = null)
{
	enforce(url.schema == "http" || url.schema == "https", "Url schema must be http(s).");
	enforce(url.host.length > 0, "Url must contain a host name.");

	auto cli = new HttpClient;
	bool ssl = url.schema == "https";
	cli.connect(url.host, url.port ? url.port : ssl ? 443 : 80, ssl);
	return cli.request((req){
			req.url = url.path.toString();
			req.headers["Host"] = url.host;
			if( requester ) requester(req);
		});
}


/**************************************************************************************************/
/* Public types                                                                                   */
/**************************************************************************************************/

class HttpClient {
	enum MaxHttpHeaderLineLength = 4096;

	private {
		string m_server;
		ushort m_port;
		TcpConnection m_conn;
		SSLContext m_ssl;
		NullOutputStream m_sink;
		InputStream m_bodyReader;
	}
	
	this()
	{
		m_sink = new NullOutputStream;
	}

	void connect(string server, ushort port = 80, bool ssl = false)
	{
		m_conn = null;
		m_server = server;
		m_port = port;
		m_ssl = ssl ? new SSLContext() : null;
	}

	void disconnect()
	{
		if( m_conn ){
			m_conn.close();
			m_conn = null;
		}
	}

	HttpClientResponse request(void delegate(HttpClientRequest req) requester)
	{
		if( !m_conn || !m_conn.connected ){
			m_conn = connectTcp(m_server, m_port);
			if( m_ssl ) m_conn.initiateSSL(m_ssl);
		} else if( m_bodyReader ){
			// dropy any existing body that was not read by the caller
			m_sink.write(m_bodyReader, 0);
			logDebug("dropped unread body.");
		}

		auto req = new HttpClientRequest(m_conn);
		req.headers["User-Agent"] = "vibe.d/"~VibeVersionString; // TODO: maybe add OS and library versions
		requester(req);
		req.headers["Connection"] = "keep-alive";
		req.headers["Accept-Encoding"] = "gzip, deflate";
		if( "Host" !in req.headers ) req.headers["Host"] = m_server;
		req.finalize();
		

		auto res = new HttpClientResponse;

		// read and parse status line ("HTTP/#.# #[ $]\r\n")
		string stln = cast(string)m_conn.readLine(MaxHttpHeaderLineLength);
		logTrace("stln: %s", stln);
		res.httpVersion = parseHttpVersion(stln);
		enforce(stln.startsWith(" "));
		stln = stln[1 .. $];
		res.statusCode = parse!int(stln);
		if( stln.length > 0 ){
			enforce(stln.startsWith(" "));
			stln = stln[1 .. $];
			res.statusPhrase = stln;
		}
		
		// read headers until an empty line is hit
		while(true){
			string ln = cast(string)m_conn.readLine(MaxHttpHeaderLineLength);
			logTrace("hdr: %s", ln);
			if( ln.length == 0 ) break;
			auto idx = ln.indexOf(":");
			auto name = ln[0 .. idx];
			ln = stripLeft(ln[idx+1 .. $]);
			if( auto ph = name in res.headers ) *ph ~= ", " ~ ln;
			else res.headers[name] = ln;
		}

		if( req.method == "HEAD" ){
			res.bodyReader = new LimitedInputStream(null, 0);
		} else {
			if( auto pte = "Transfer-Encoding" in res.headers ){
				enforce(*pte == "chunked");
				res.bodyReader = new ChunkedInputStream(m_conn);
			} else {
				if( auto pcl = "Content-Length" in res.headers )
					res.bodyReader = new LimitedInputStream(m_conn, to!ulong(*pcl));
				else res.bodyReader = m_conn;
			}
			// TODO: handle content-encoding: deflate, gzip
		}

		if( auto pce = "Content-Encoding" in res.headers ){
			if( *pce == "deflate" ) res.bodyReader = new DeflateInputStream(res.bodyReader);
			else if( *pce == "gzip" ) res.bodyReader = new GzipInputStream(res.bodyReader);
			else enforce(false, "Unsuported content encoding: "~*pce);
		}

		m_bodyReader = res.bodyReader;

		return res;
	}
}

final class HttpClientRequest : HttpRequest {
	private {
		OutputStream m_bodyWriter;
	}

	private this(TcpConnection conn)
	{
		super(conn);
	}

	void writeBody(InputStream data, ulong length)
	{
		headers["Content-Length"] = to!string(length);
		bodyWriter.write(data, length);
	}
	
	void writeBody(ubyte[] data, string content_type = null)
	{
		if( content_type ) headers["Content-Type"] = content_type;
		headers["Content-Length"] = to!string(data.length);
		bodyWriter.write(data);
	}
	
	void writeBody(string[string] form)
	{
		assert(false, "TODO");
	}

	void writeJsonBody(T)(T data)
	{
		writeBody(cast(ubyte[])serializeToJson(data).toString(), "application/json");
	}

	void writePart(MultiPart part)
	{
		assert(false, "TODO");
	}

	@property OutputStream bodyWriter()
	{
		if( m_bodyWriter ) return m_bodyWriter;
		writeHeader();
		m_bodyWriter = m_conn;
		return m_bodyWriter;
	}

	private void writeHeader()
	{
		auto app = appender!string();
		formattedWrite(app, "%s %s %s\r\n", method, url, getHttpVersionString(httpVersion));
		m_conn.write(app.data, false);
		
		foreach( k, v; headers ){
			auto app2 = appender!string();
			formattedWrite(app2, "%s: %s\r\n", k, v);
			m_conn.write(app2.data, false);
		}
		m_conn.write("\r\n", true);
	}

	private void finalize()
	{
		bodyWriter().flush();
	}
}

final class HttpClientResponse : HttpResponse {
	InputStream bodyReader;

	Json readJson(){
		auto bdy = bodyReader.readAll();
		auto str = cast(string)bdy;
		return parseJson(str);
	}
}
