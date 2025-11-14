# Web Crawler Example - Async (Phase 2 - Future)
# NOTE: This example requires Phase 2 async executor
# Currently shows intended syntax for concurrent HTTP requests

# async def fetch_url(url):
#     """Fetch a single URL asynchronously"""
#     print("Fetching: " + url)
#     response = await http_get(url)
#     print("Got response from: " + url)
#     return response
#
# async def crawl_urls(urls):
#     """Crawl multiple URLs concurrently"""
#     tasks = []
#     for url in urls:
#         task = fetch_url(url)
#         tasks.append(task)
#
#     results = await gather(tasks)
#     return results
#
# # Main execution
# urls = [
#     "http://example.com",
#     "http://example.org",
#     "http://example.net",
#     "http://example.edu",
#     "http://example.info",
# ]
#
# print("Starting concurrent web crawler...")
# results = await crawl_urls(urls)
#
# for i in range(len(results)):
#     status = results[i][0]
#     body = results[i][1]
#     print("URL " + str(i) + " - Status: " + str(status))
#     print("Body preview: " + body[:100] + "...")
#     print("---")
#
# print("Concurrent crawling complete!")

# Placeholder for Phase 1 - just show what async will look like
print("This example requires Phase 2 async executor")
print("See web_crawler.py for working sequential version")
