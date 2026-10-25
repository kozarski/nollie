// Reads the words in one screenshot with the Mac's own text recognition (Vision), for Ask first.
//   osascript -l JavaScript screen_text.js /path/to/screen.png
// Prints {"width", "height", "items": [{"text", "x", "y", "w", "h"}]} in image pixels, top-left origin.
ObjC.import('Foundation');
ObjC.import('AppKit');
ObjC.import('Vision');

function run(argv) {
  const path = argv[0];
  if (!path) return JSON.stringify({error: 'no image'});
  const rep = $.NSBitmapImageRep.imageRepWithContentsOfFile(path);
  if (!rep || rep.isNil()) return JSON.stringify({error: 'cannot read image'});
  const W = Number(rep.pixelsWide), H = Number(rep.pixelsHigh);
  const request = $.VNRecognizeTextRequest.alloc.init;
  request.recognitionLevel = 0;  // accurate
  request.usesLanguageCorrection = false;
  const handler = $.VNImageRequestHandler.alloc.initWithURLOptions($.NSURL.fileURLWithPath(path),
                                                                   $.NSDictionary.dictionary);
  const error = Ref();
  if (!handler.performRequestsError($.NSArray.arrayWithObject(request), error)) {
    return JSON.stringify({error: 'recognition failed'});
  }
  const items = [];
  const results = request.results;
  const count = (results && !results.isNil()) ? Number(results.count) : 0;
  for (let i = 0; i < count; i++) {
    const observation = results.objectAtIndex(i);
    const candidates = observation.topCandidates(1);
    if (Number(candidates.count) === 0) continue;
    const box = observation.boundingBox;  // normalised, bottom-left origin
    items.push({
      text: ObjC.unwrap(candidates.objectAtIndex(0).string),
      x: Math.round(box.origin.x * W),
      y: Math.round((1 - box.origin.y - box.size.height) * H),
      w: Math.round(box.size.width * W),
      h: Math.round(box.size.height * H)
    });
  }
  return JSON.stringify({width: W, height: H, items: items});
}
