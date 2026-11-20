"""LAB connected components within a configurable bench observation window."""
import config as C
from color_core import COLORS, choose_color
from arrow_core import extract_mask, classify
from arrow_templates import TEMPLATES

DEFAULT_LAB = ((20,100,21,127,5,127), (15,95,-128,-16,-5,100),
               (5,80,-10,100,-128,-16), (35,100,-15,20,30,127))


def roi_rect(width,height,tracking=False,field=False):
    coords = C.FIELD_COLOR_ROI if field else (C.TRACK_ROI if tracking else C.COLOR_ROI)
    rx,ry,rw,rh = coords
    if rx<0 or ry<0 or rw<=0 or rh<=0 or rx+rw>1 or ry+rh>1:
        raise ValueError("COLOR_ROI must fit normalized image coordinates")
    return int(rx*width),int(ry*height),int(rw*width),int(rh*height)


def looks_like_arrow(img,box):
    # Suppress blue signs matching the known white-arrow geometry, not all blue objects.
    mask,count = extract_mask(img.get_pixel,box,32,C.WHITE_MIN,C.WHITE_SPREAD)
    if count < 25:
        return False
    return classify(mask,TEMPLATES,.40,.05)["label"] != "unknown"


def extend_warm_box(img, label, box, roi):
    """Use weak same-hue pixels next to an existing red/yellow seed near an edge."""
    x,y,w,h = box
    left, _, width, _ = roi
    right = left + width
    frame_width = img.width()
    reach = min(h, frame_width//6)
    rows = [y+h*i//10 for i in range(2,9)]
    edges = [x, x+w]
    for side, bound, direction in ((0,left,-1), (1,right,1)):
        original = edges[side]
        if abs(bound-original)>frame_width//5:
            continue
        # Inspect adjacent columns in order. One weak gap can be a cube seam;
        # two in a row stop growth. Keep the last column with color evidence.
        distance = min(reach, abs(bound-original))
        gap = 0
        offset = 1
        while offset<=distance:
            column = original-offset if direction<0 else original+offset-1
            votes = 0
            for row in rows:
                r,g,b = img.get_pixel(column,row)
                if label=='red':
                    votes += r-g>=12 and r-b>=8
                else:
                    votes += min(r,g)-b>=10 and -20<=r-g<=26
            if votes>=5:
                edges[side] = original+direction*offset
                gap = 0
            else:
                gap += 1
                if gap>=2:
                    break
            if offset==distance:
                break
            offset = min(offset+3,distance)
    return edges[0],y,edges[1]-edges[0],h


def inside_sign(blob, box):
    if not box:
        return False
    x,y,w,h = box
    cx,cy = blob.x()+blob.w()/2,blob.y()+blob.h()/2
    return x<=cx<x+w and y<=cy<y+h


def detect_colors(img,tracking=False,field=False,sign_box=None,parking_box=None):
    roi = roi_rect(img.width(),img.height(),tracking,field)
    minimum = getattr(C,"COLOR_MIN_PIXELS",500)
    thresholds = getattr(C,"COLOR_LAB",DEFAULT_LAB)
    if field:
        thresholds = getattr(C,"FIELD_COLOR_LAB",thresholds)
    blobs = img.find_blobs(list(thresholds),roi=roi,
                          pixels_threshold=minimum,area_threshold=minimum,
                          merge=False)
    candidates = []
    rejected=[]
    present = False
    x0,y0,rw,rh = roi
    for b in blobs:
        def reject(reason):
            if len(rejected)<32:
                rejected.append({'box':b.rect(),'code':b.code(),'pixels':b.pixels(),'reason':reason})
        if b.pixels() < minimum or b.w()<16 or b.h()<16:
            reject('small')
            continue
        # Reject ROI-clipped objects until they are fully inside it.
        clipped=b.x()<=x0+1 or b.y()<=y0+1 or b.x()+b.w()>=x0+rw-1 or b.y()+b.h()>=y0+rh-1
        if clipped and not tracking:
            reject('clipped')
            continue
        if not .35<=b.w()/b.h()<=2.8 or b.pixels()/(b.w()*b.h())<.35:
            reject('shape_or_density')
            continue
        code = b.code()
        if code not in (1,2,4,8):
            reject('mixed_threshold')
            continue
        label = COLORS[(1,2,4,8).index(code)]
        if field and label == "blue":
            if inside_sign(b,sign_box):
                reject('arrow_sign')
                continue
            if inside_sign(b,parking_box):
                reject('parking_sign')
                continue
        if label=="blue" and not clipped and looks_like_arrow(img,b.rect()):
            reject('arrow_sign')
            continue
        # Only eligible targets block rearming. Clipped background patches,
        # tiny/noisy shapes and vetoed arrow signs aren't an ongoing color cube.
        present = True
        box = b.rect()
        candidate = {"label":label,"box":box,"pixels":b.pixels(),'clipped':clipped}
        if field and label in ('red','yellow'):
            recovered = extend_warm_box(img,label,box,roi)
            if recovered != box:
                candidate['core_box'] = box
                candidate['box'] = recovered
                candidate['clipped'] = clipped or recovered[0]<=x0+1 or recovered[0]+recovered[2]>=x0+rw-1
        candidates.append(candidate)
    candidates.sort(key=lambda c:c['pixels'],reverse=True)
    discarded=max(0,len(candidates)-24)
    candidates=candidates[:24]
    best = choose_color(candidates,getattr(C,"COLOR_DOMINANCE",1.6))
    if best is None:
        return {"label":"unknown","box":None,"pixels":0,"present":present,"roi":roi,
                'candidates':candidates,'rejected':rejected,'candidate_overflow':discarded}
    result = dict(best)
    result.update({"present":True,"roi":roi})
    result.update({'candidates':candidates,'rejected':rejected,'candidate_overflow':discarded})
    return result


def detect_multi_colors(img,field=False,sign_box=None,parking_box=None):
    return detect_colors(img,tracking=True,field=field,sign_box=sign_box,parking_box=parking_box)
