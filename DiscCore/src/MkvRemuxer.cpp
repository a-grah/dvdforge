// Lossless remux of a staged DVD title (MPEG program stream) into Matroska.
//
// Video, AC3, DTS and MPEG audio and DVD subtitles are copied bit for bit.
// LPCM has no Matroska codec ID, so it is decoded and re-encoded as FLAC,
// which is also lossless.
//
// The tricky part is time: every DVD cell may restart the MPEG clock (an "STC
// discontinuity"). Packets are buffered at the start of each cell until its
// first video timestamp is known; if that timestamp doesn't continue the
// output timeline, the whole cell is shifted so playback stays continuous.

#include "DiscCore.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <deque>
#include <filesystem>
#include <map>
#include <memory>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/opt.h>
}

namespace fs = std::filesystem;

namespace dc {

namespace {

constexpr AVRational kMpegTimeBase{1, 90000};
/// A jump bigger than this between cells is treated as a clock discontinuity.
constexpr int64_t kDiscontinuityThreshold = 45000;  // 0.5 s
/// Give up waiting for a cell's first video timestamp after this many packets.
constexpr size_t kMaxPendingPackets = 4096;

std::string averror(int code) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, buf, sizeof buf);
    return buf;
}

/// MPEG-PS stream id (AVStream::id from libavformat's mpegps demuxer) for a
/// DVD stream id from the IFO. MPEG audio is a real PES stream (0x1C0+n),
/// everything else is a private_stream_1 substream keyed by its own id.
int psStreamId(int dvdStreamId) {
    return (dvdStreamId >= 0xC0 && dvdStreamId <= 0xC7) ? 0x100 + dvdStreamId : dvdStreamId;
}

AVCodecID codecFor(AudioCodec c) {
    switch (c) {
    case AudioCodec::ac3: return AV_CODEC_ID_AC3;
    case AudioCodec::dts: return AV_CODEC_ID_DTS;
    case AudioCodec::mpeg: return AV_CODEC_ID_MP2;
    case AudioCodec::lpcm: return AV_CODEC_ID_PCM_DVD;
    default: return AV_CODEC_ID_NONE;
    }
}

/// VobSub "idx" header carrying the subtitle palette, converted from the
/// IFO's YCrCb entries to RGB.
std::string vobsubHeader(int width, int height, const std::vector<uint32_t>& palette) {
    auto clamp = [](double v) { return static_cast<int>(std::clamp(std::lround(v), 0L, 255L)); };
    std::string s = "size: " + std::to_string(width) + "x" + std::to_string(height) + "\npalette: ";
    for (size_t i = 0; i < 16; ++i) {
        uint32_t e = i < palette.size() ? palette[i] : 0;
        double y = (e >> 16) & 0xff, cr = (e >> 8) & 0xff, cb = e & 0xff;
        char rgb[8];
        snprintf(rgb, sizeof rgb, "%02x%02x%02x", clamp(y + 1.402 * (cr - 128)),
                 clamp(y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)), clamp(y + 1.772 * (cb - 128)));
        s += rgb;
        s += i < 15 ? ", " : "\n";
    }
    return s;
}

struct PacketDeleter {
    void operator()(AVPacket* p) const { av_packet_free(&p); }
};
using PacketPtr = std::unique_ptr<AVPacket, PacketDeleter>;

} // namespace

std::string matroskaLanguage(const std::string& code) {
    // ISO 639-1 → ISO 639-2/B for the languages DVDs realistically carry.
    static const std::map<std::string, std::string> table{
        {"ar", "ara"}, {"bg", "bul"}, {"bn", "ben"}, {"bo", "tib"}, {"ca", "cat"}, {"cs", "cze"},
        {"cy", "wel"}, {"da", "dan"}, {"de", "ger"}, {"el", "gre"}, {"en", "eng"}, {"es", "spa"},
        {"et", "est"}, {"eu", "baq"}, {"fa", "per"}, {"fi", "fin"}, {"fr", "fre"}, {"ga", "gle"},
        {"gl", "glg"}, {"he", "heb"}, {"hi", "hin"}, {"hr", "hrv"}, {"hu", "hun"}, {"hy", "arm"},
        {"id", "ind"}, {"is", "ice"}, {"it", "ita"}, {"ja", "jpn"}, {"ka", "geo"}, {"ko", "kor"},
        {"la", "lat"}, {"lt", "lit"}, {"lv", "lav"}, {"mk", "mac"}, {"ms", "may"}, {"my", "bur"},
        {"nl", "dut"}, {"no", "nor"}, {"pl", "pol"}, {"pt", "por"}, {"ro", "rum"}, {"ru", "rus"},
        {"sk", "slo"}, {"sl", "slv"}, {"sq", "alb"}, {"sr", "srp"}, {"sv", "swe"}, {"ta", "tam"},
        {"te", "tel"}, {"th", "tha"}, {"tr", "tur"}, {"uk", "ukr"}, {"ur", "urd"}, {"vi", "vie"},
        {"zh", "chi"},
    };
    std::string lower = code;
    for (char& c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    auto it = table.find(lower);
    return it == table.end() ? "und" : it->second;
}

class RemuxJob {
public:
    explicit RemuxJob(RemuxRequest request) : req_(std::move(request)) {}
    ~RemuxJob() { cleanup(); }

    RemuxResult run();
    RemuxProgress progress() const { return {fraction_.load()}; }
    void cancel() { cancelled_ = true; }

private:
    struct Track {
        AVStream* out = nullptr;
        int psId = 0;
        bool isVideo = false;
        bool isAudio = false;
        int64_t lastDts = AV_NOPTS_VALUE;  // output timeline, 90 kHz
        PacketPtr held;                    // audio: one packet of look-ahead for timestamp repair
        // LPCM → FLAC
        AVCodecContext* dec = nullptr;
        AVCodecContext* enc = nullptr;
        AVAudioFifo* fifo = nullptr;
        int64_t nextSample = AV_NOPTS_VALUE;
    };
    struct Pending {
        Track* track;
        PacketPtr packet;
    };

    bool openInput();
    bool createOutput();
    bool addVideo();
    bool addAudio(const AudioTrack& a, bool isDefault);
    void addSubtitle(const SubtitleTrack& s);
    void addChapters();
    void addTags();
    bool remux();

    Track* trackFor(int inputIndex);
    int cellForPosition(int64_t pos) const;
    void resolveCellOffset(int64_t firstVideoTs);
    bool flushPending();
    bool emit(Track& t, AVPacket* pkt);
    bool emitAudio(Track& t, AVPacket* pkt);
    bool write(Track& t, AVPacket* pkt);
    bool writeLpcm(Track& t, AVPacket* pkt);
    bool encodeFifo(Track& t, int samples);
    bool drainEncoder(Track& t);
    bool finishLpcm(Track& t);
    bool fail(const std::string& message, int code = 0);
    void cleanup();

    RemuxRequest req_;
    RemuxResult result_;
    std::atomic<double> fraction_{0};
    std::atomic<bool> cancelled_{false};

    AVFormatContext* in_ = nullptr;
    AVFormatContext* out_ = nullptr;
    std::string tempPath_;
    std::deque<Track> tracks_;            // deque: stable addresses
    std::map<int, Track*> byInputIndex_;  // nullptr = discard
    std::vector<int64_t> cellEnds_;       // byte offset where each cell ends
    int videoWidth_ = 720, videoHeight_ = 480;
    int64_t frameTicks_ = 3003;

    int currentCell_ = -1;
    bool awaitingVideo_ = true;
    bool offsetKnown_ = false;
    int64_t offset_ = 0;
    int64_t lastVideoEnd_ = AV_NOPTS_VALUE;
    std::vector<Pending> pending_;
    int monotonicFixes_ = 0;
    int untimedDropped_ = 0;
    int audioRepairs_ = 0;
};

// MARK: - Setup

bool RemuxJob::fail(const std::string& message, int code) {
    result_.error = code ? message + ": " + averror(code) : message;
    return false;
}

bool RemuxJob::openInput() {
    AVDictionary* opts = nullptr;
    av_dict_set(&opts, "probesize", "67108864", 0);
    av_dict_set(&opts, "analyzeduration", "30000000", 0);
    const AVInputFormat* mpegps = av_find_input_format("mpeg");
    int ret = avformat_open_input(&in_, req_.stagingPath.c_str(), mpegps, &opts);
    av_dict_free(&opts);
    if (ret < 0) return fail("Could not open the staging file", ret);
    // MPEG-PS only stamps some frames; Matroska needs a PTS on every block.
    // GENPTS fills the gaps by parsing ahead (B-frame reordering included).
    in_->flags |= AVFMT_FLAG_GENPTS;
    if ((ret = avformat_find_stream_info(in_, nullptr)) < 0) return fail("Could not analyse the title", ret);

    uint64_t bytes = 0;
    for (const CellRange& c : req_.title.cells) {
        bytes += (uint64_t(c.lastSector) - c.firstSector + 1) * kSectorSize;
        cellEnds_.push_back(static_cast<int64_t>(bytes));
    }
    frameTicks_ = req_.title.pal ? 3600 : 3003;
    return true;
}

bool RemuxJob::createOutput() {
    tempPath_ = req_.outputPath + ".part";
    std::error_code ec;
    fs::create_directories(fs::path(req_.outputPath).parent_path(), ec);
    int ret = avformat_alloc_output_context2(&out_, nullptr, "matroska", tempPath_.c_str());
    if (ret < 0) return fail("Could not create the Matroska muxer", ret);

    if (!addVideo()) return false;
    bool first = true;
    for (int number : req_.audioTracks) {
        auto a = std::find_if(req_.title.audio.begin(), req_.title.audio.end(),
                              [&](const AudioTrack& t) { return t.number == number; });
        if (a == req_.title.audio.end()) continue;
        if (!addAudio(*a, first)) return false;
        first = false;
    }
    for (int number : req_.subtitleTracks) {
        auto s = std::find_if(req_.title.subtitles.begin(), req_.title.subtitles.end(),
                              [&](const SubtitleTrack& t) { return t.number == number; });
        if (s != req_.title.subtitles.end()) addSubtitle(*s);
    }
    addChapters();
    addTags();

    if ((ret = avio_open(&out_->pb, tempPath_.c_str(), AVIO_FLAG_WRITE)) < 0)
        return fail("Could not create " + tempPath_, ret);
    if ((ret = avformat_write_header(out_, nullptr)) < 0) return fail("Could not write the MKV header", ret);
    return true;
}

bool RemuxJob::addVideo() {
    AVStream* src = nullptr;
    for (unsigned i = 0; i < in_->nb_streams; ++i)
        if (in_->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) { src = in_->streams[i]; break; }
    if (!src) return fail("The title has no video stream.");

    Track& t = tracks_.emplace_back();
    t.isVideo = true;
    t.psId = src->id;
    t.out = avformat_new_stream(out_, nullptr);
    avcodec_parameters_copy(t.out->codecpar, src->codecpar);
    t.out->codecpar->codec_tag = 0;
    t.out->avg_frame_rate = src->avg_frame_rate;
    t.out->r_frame_rate = src->r_frame_rate;
    if (t.out->codecpar->width > 0) {
        videoWidth_ = t.out->codecpar->width;
        videoHeight_ = t.out->codecpar->height;
    }
    // Display aspect from the IFO (authoritative for DVD), as a sample aspect ratio.
    if (req_.title.aspect != AspectRatio::unknown) {
        AVRational dar = req_.title.aspect == AspectRatio::sixteenByNine ? AVRational{16, 9} : AVRational{4, 3};
        AVRational sar;
        av_reduce(&sar.num, &sar.den, int64_t(dar.num) * videoHeight_, int64_t(dar.den) * videoWidth_, 1 << 16);
        t.out->sample_aspect_ratio = sar;
        t.out->codecpar->sample_aspect_ratio = sar;
    }
    t.out->disposition = AV_DISPOSITION_DEFAULT;
    return true;
}

bool RemuxJob::addAudio(const AudioTrack& a, bool isDefault) {
    AVStream* src = nullptr;
    int psId = psStreamId(a.streamId);
    for (unsigned i = 0; i < in_->nb_streams; ++i)
        if (in_->streams[i]->id == psId) { src = in_->streams[i]; break; }

    Track& t = tracks_.emplace_back();
    t.psId = psId;
    t.isAudio = true;
    t.out = avformat_new_stream(out_, nullptr);

    if (a.codec == AudioCodec::lpcm) {
        const AVCodec* decoder = avcodec_find_decoder(AV_CODEC_ID_PCM_DVD);
        const AVCodec* encoder = avcodec_find_encoder(AV_CODEC_ID_FLAC);
        t.dec = avcodec_alloc_context3(decoder);
        t.enc = avcodec_alloc_context3(encoder);
        if (src) avcodec_parameters_to_context(t.dec, src->codecpar);
        if (!t.dec->sample_rate) t.dec->sample_rate = a.sampleRate;
        if (!t.dec->ch_layout.nb_channels) av_channel_layout_default(&t.dec->ch_layout, a.channels);
        t.dec->pkt_timebase = kMpegTimeBase;
        int ret = avcodec_open2(t.dec, decoder, nullptr);
        if (ret < 0) return fail("Could not open the LPCM decoder", ret);

        bool wide = a.bitsPerSample > 16;
        t.enc->sample_rate = a.sampleRate;
        av_channel_layout_default(&t.enc->ch_layout, a.channels);
        t.enc->sample_fmt = wide ? AV_SAMPLE_FMT_S32 : AV_SAMPLE_FMT_S16;
        t.enc->bits_per_raw_sample = wide ? 24 : 16;
        t.enc->time_base = {1, a.sampleRate};
        t.enc->compression_level = 8;
        if (out_->oformat->flags & AVFMT_GLOBALHEADER) t.enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if ((ret = avcodec_open2(t.enc, encoder, nullptr)) < 0) return fail("Could not open the FLAC encoder", ret);
        avcodec_parameters_from_context(t.out->codecpar, t.enc);
        t.out->time_base = t.enc->time_base;
        t.fifo = av_audio_fifo_alloc(t.enc->sample_fmt, a.channels, t.enc->frame_size ? t.enc->frame_size * 2 : 8192);
    } else if (src) {
        avcodec_parameters_copy(t.out->codecpar, src->codecpar);
        t.out->codecpar->codec_tag = 0;
    } else {
        // Not seen while probing (it may start late); describe it from the IFO.
        t.out->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
        t.out->codecpar->codec_id = codecFor(a.codec);
        t.out->codecpar->sample_rate = a.sampleRate;
        av_channel_layout_default(&t.out->codecpar->ch_layout, a.channels);
    }

    if (!a.language.empty()) av_dict_set(&t.out->metadata, "language", matroskaLanguage(a.language).c_str(), 0);
    if (a.purpose == TrackPurpose::commentary) av_dict_set(&t.out->metadata, "title", "Commentary", 0);
    if (a.purpose == TrackPurpose::visuallyImpaired)
        av_dict_set(&t.out->metadata, "title", "Audio description", 0);
    t.out->disposition = isDefault ? AV_DISPOSITION_DEFAULT : 0;
    if (a.purpose == TrackPurpose::commentary) t.out->disposition |= AV_DISPOSITION_COMMENT;
    if (a.purpose == TrackPurpose::visuallyImpaired) t.out->disposition |= AV_DISPOSITION_VISUAL_IMPAIRED;
    return true;
}

void RemuxJob::addSubtitle(const SubtitleTrack& s) {
    Track& t = tracks_.emplace_back();
    t.psId = psStreamId(s.streamId);
    t.out = avformat_new_stream(out_, nullptr);
    AVCodecParameters* par = t.out->codecpar;
    par->codec_type = AVMEDIA_TYPE_SUBTITLE;
    par->codec_id = AV_CODEC_ID_DVD_SUBTITLE;
    par->width = videoWidth_;
    par->height = videoHeight_;
    std::string idx = vobsubHeader(videoWidth_, videoHeight_, req_.title.palette);
    par->extradata = static_cast<uint8_t*>(av_mallocz(idx.size() + AV_INPUT_BUFFER_PADDING_SIZE));
    std::copy(idx.begin(), idx.end(), par->extradata);
    par->extradata_size = static_cast<int>(idx.size());
    if (!s.language.empty()) av_dict_set(&t.out->metadata, "language", matroskaLanguage(s.language).c_str(), 0);
    if (s.purpose == TrackPurpose::commentary) av_dict_set(&t.out->metadata, "title", "Commentary", 0);
    t.out->disposition = 0;
}

void RemuxJob::addChapters() {
    for (const Chapter& c : req_.title.chapters) {
        auto* ch = static_cast<AVChapter*>(av_mallocz(sizeof(AVChapter)));
        if (!ch) return;
        ch->id = c.number;
        ch->time_base = kMpegTimeBase;
        ch->start = static_cast<int64_t>(c.startTicks);
        ch->end = static_cast<int64_t>(c.startTicks + c.durationTicks);
        av_dict_set(&ch->metadata, "title", ("Chapter " + std::to_string(c.number)).c_str(), 0);
        auto** grown = static_cast<AVChapter**>(av_realloc_array(out_->chapters, out_->nb_chapters + 1, sizeof(AVChapter*)));
        if (!grown) {
            av_dict_free(&ch->metadata);
            av_free(ch);
            return;
        }
        out_->chapters = grown;
        out_->chapters[out_->nb_chapters++] = ch;
    }
}

void RemuxJob::addTags() {
    auto tag = [&](const char* key, const std::string& value) {
        if (!value.empty()) av_dict_set(&out_->metadata, key, value.c_str(), 0);
    };
    char date[32];
    std::time_t now = std::time(nullptr);
    std::strftime(date, sizeof date, "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&now));
    tag("title", req_.movieTitle);
    tag("DVDFORGE_DISC_ID", req_.discId);
    tag("DVDFORGE_SOURCE_TITLE", std::to_string(req_.title.number));
    tag("DVDFORGE_RIP_DATE", date);
    tag("DVDFORGE_DRIVE", req_.driveModel);
    tag("DVDFORGE_BAD_SECTORS", std::to_string(req_.badSectors));
    tag("DVDFORGE_UNSTABLE_SECTORS", std::to_string(req_.unstableSectors));
}

// MARK: - Packet flow

RemuxJob::Track* RemuxJob::trackFor(int inputIndex) {
    if (auto it = byInputIndex_.find(inputIndex); it != byInputIndex_.end()) return it->second;
    AVStream* st = in_->streams[inputIndex];
    Track* match = nullptr;
    for (Track& t : tracks_) {
        if (t.isVideo ? st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && st->id == t.psId : st->id == t.psId) {
            match = &t;
            break;
        }
    }
    byInputIndex_[inputIndex] = match;
    return match;
}

int RemuxJob::cellForPosition(int64_t pos) const {
    if (pos < 0) return currentCell_;
    auto it = std::upper_bound(cellEnds_.begin(), cellEnds_.end(), pos);
    return static_cast<int>(std::min<size_t>(it - cellEnds_.begin(), cellEnds_.size() - 1));
}

static int64_t packetTime(const AVPacket* p) { return p->dts != AV_NOPTS_VALUE ? p->dts : p->pts; }

void RemuxJob::resolveCellOffset(int64_t firstVideoTs) {
    if (!offsetKnown_) {
        // Start the output at zero, including any audio that precedes the first frame.
        int64_t earliest = firstVideoTs;
        for (const Pending& p : pending_) {
            int64_t ts = packetTime(p.packet.get());
            if (ts != AV_NOPTS_VALUE) earliest = std::min(earliest, ts);
        }
        offset_ = -earliest;
        offsetKnown_ = true;
        return;
    }
    if (lastVideoEnd_ == AV_NOPTS_VALUE) return;
    int64_t expected = lastVideoEnd_;
    if (std::llabs(firstVideoTs + offset_ - expected) > kDiscontinuityThreshold) {
        offset_ = expected - firstVideoTs;
        ++result_.timestampDiscontinuities;
    }
}

bool RemuxJob::flushPending() {
    if (!offsetKnown_) {
        // No video timestamp at all in this stretch; anchor on whatever we have.
        int64_t earliest = AV_NOPTS_VALUE;
        for (const Pending& p : pending_) {
            int64_t ts = packetTime(p.packet.get());
            if (ts != AV_NOPTS_VALUE && (earliest == AV_NOPTS_VALUE || ts < earliest)) earliest = ts;
        }
        if (earliest != AV_NOPTS_VALUE) {
            offset_ = -earliest;
            offsetKnown_ = true;
        }
    }
    for (Pending& p : pending_)
        if (!emit(*p.track, p.packet.get())) return false;
    pending_.clear();
    awaitingVideo_ = false;
    return true;
}

bool RemuxJob::emit(Track& t, AVPacket* pkt) {
    if (pkt->pts == AV_NOPTS_VALUE) {
        if (pkt->dts == AV_NOPTS_VALUE || t.isVideo) {
            ++untimedDropped_;  // nothing to place it with (e.g. before the first timestamp)
            return true;
        }
        pkt->pts = pkt->dts;
    }
    if (pkt->pts != AV_NOPTS_VALUE) pkt->pts += offset_;
    if (pkt->dts != AV_NOPTS_VALUE) pkt->dts += offset_;

    if (t.isVideo) {
        int64_t ts = packetTime(pkt);
        if (ts != AV_NOPTS_VALUE) {
            int64_t end = std::max(ts, pkt->pts != AV_NOPTS_VALUE ? pkt->pts : ts) + frameTicks_;
            if (lastVideoEnd_ == AV_NOPTS_VALUE || end > lastVideoEnd_) lastVideoEnd_ = end;
        }
    }
    if (t.dec) return writeLpcm(t, pkt);
    if (t.isAudio) return emitAudio(t, pkt);
    return write(t, pkt);
}

/// The demuxer sometimes gives an audio frame the timestamp of the frame after
/// it (a PES timestamp attributed one frame early), which shows up as the next
/// packet not moving forward. With one packet held back, such a frame is put
/// back right after its predecessor.
bool RemuxJob::emitAudio(Track& t, AVPacket* pkt) {
    if (!t.held) {
        t.held.reset(av_packet_alloc());
        av_packet_move_ref(t.held.get(), pkt);
        return true;
    }
    AVPacket* held = t.held.get();
    int64_t heldTs = packetTime(held), nextTs = packetTime(pkt);
    if (heldTs != AV_NOPTS_VALUE && nextTs != AV_NOPTS_VALUE && nextTs <= heldTs && t.lastDts != AV_NOPTS_VALUE) {
        int64_t duration = held->duration > 0 ? held->duration : (nextTs - t.lastDts) / 2;
        int64_t repaired = t.lastDts + duration;
        if (repaired > t.lastDts && repaired < nextTs) {
            int64_t shift = repaired - heldTs;
            held->pts += shift;
            if (held->dts != AV_NOPTS_VALUE) held->dts += shift;
            ++audioRepairs_;
        }
    }
    if (!write(t, held)) return false;
    av_packet_unref(held);
    av_packet_move_ref(held, pkt);
    return true;
}

bool RemuxJob::write(Track& t, AVPacket* pkt) {
    // Keep each track's DTS strictly increasing across re-based cell joins.
    int64_t ts = packetTime(pkt);
    if (ts != AV_NOPTS_VALUE && t.lastDts != AV_NOPTS_VALUE && ts <= t.lastDts) {
        int64_t shift = t.lastDts + 1 - ts;
        if (pkt->pts != AV_NOPTS_VALUE) pkt->pts += shift;
        if (pkt->dts != AV_NOPTS_VALUE) pkt->dts += shift;
        ++monotonicFixes_;
        ts += shift;
    }
    if (ts != AV_NOPTS_VALUE) {
        if (ts < 0) return true;  // before the start of the title; drop
        t.lastDts = ts;
    }

    pkt->stream_index = t.out->index;
    pkt->pos = -1;
    av_packet_rescale_ts(pkt, kMpegTimeBase, t.out->time_base);
    int ret = av_interleaved_write_frame(out_, pkt);
    return ret >= 0 || fail("Writing the MKV failed", ret);
}

bool RemuxJob::writeLpcm(Track& t, AVPacket* pkt) {
    int ret = avcodec_send_packet(t.dec, pkt);
    if (ret < 0) {
        result_.warnings.push_back("Skipped an undecodable LPCM packet: " + averror(ret));
        return true;
    }
    AVFrame* frame = av_frame_alloc();
    while ((ret = avcodec_receive_frame(t.dec, frame)) >= 0) {
        if (frame->format != t.enc->sample_fmt || frame->ch_layout.nb_channels != t.enc->ch_layout.nb_channels) {
            av_frame_free(&frame);
            return fail("LPCM format differs from what the IFO declared.");
        }
        if (t.nextSample == AV_NOPTS_VALUE)
            t.nextSample = frame->pts != AV_NOPTS_VALUE
                               ? av_rescale_q(std::max<int64_t>(frame->pts, 0), kMpegTimeBase, t.enc->time_base)
                               : 0;
        av_audio_fifo_write(t.fifo, reinterpret_cast<void**>(frame->extended_data), frame->nb_samples);
        av_frame_unref(frame);
        while (av_audio_fifo_size(t.fifo) >= t.enc->frame_size)
            if (!encodeFifo(t, t.enc->frame_size)) {
                av_frame_free(&frame);
                return false;
            }
    }
    av_frame_free(&frame);
    return true;
}

bool RemuxJob::encodeFifo(Track& t, int samples) {
    AVFrame* frame = av_frame_alloc();
    frame->nb_samples = samples;
    frame->format = t.enc->sample_fmt;
    frame->sample_rate = t.enc->sample_rate;
    av_channel_layout_copy(&frame->ch_layout, &t.enc->ch_layout);
    if (av_frame_get_buffer(frame, 0) < 0) {
        av_frame_free(&frame);
        return fail("Out of memory while encoding FLAC.");
    }
    av_audio_fifo_read(t.fifo, reinterpret_cast<void**>(frame->data), samples);
    frame->pts = t.nextSample;
    t.nextSample += samples;
    int ret = avcodec_send_frame(t.enc, frame);
    av_frame_free(&frame);
    if (ret < 0) return fail("FLAC encoding failed", ret);
    return drainEncoder(t);
}

bool RemuxJob::drainEncoder(Track& t) {
    AVPacket* pkt = av_packet_alloc();
    int ret;
    while ((ret = avcodec_receive_packet(t.enc, pkt)) >= 0) {
        pkt->stream_index = t.out->index;
        av_packet_rescale_ts(pkt, t.enc->time_base, t.out->time_base);
        if ((ret = av_interleaved_write_frame(out_, pkt)) < 0) {
            av_packet_free(&pkt);
            return fail("Writing the MKV failed", ret);
        }
    }
    av_packet_free(&pkt);
    return true;
}

bool RemuxJob::finishLpcm(Track& t) {
    if (!writeLpcm(t, nullptr)) return false;  // drain the decoder
    int remaining = av_audio_fifo_size(t.fifo);
    if (remaining > 0 && !encodeFifo(t, remaining)) return false;
    avcodec_send_frame(t.enc, nullptr);
    return drainEncoder(t);
}

bool RemuxJob::remux() {
    int64_t fileSize = avio_size(in_->pb);
    PacketPtr pkt(av_packet_alloc());
    int ret;
    while ((ret = av_read_frame(in_, pkt.get())) >= 0) {
        if (cancelled_) return false;
        if (fileSize > 0 && pkt->pos >= 0) fraction_ = double(pkt->pos) / double(fileSize);

        Track* t = trackFor(pkt->stream_index);
        if (!t) {
            av_packet_unref(pkt.get());
            continue;
        }
        int cell = cellForPosition(pkt->pos);
        if (cell != currentCell_) {
            if (!awaitingVideo_ && !pending_.empty() && !flushPending()) return false;
            currentCell_ = cell;
            awaitingVideo_ = true;
        }

        if (!awaitingVideo_) {
            if (!emit(*t, pkt.get())) return false;
            av_packet_unref(pkt.get());
            continue;
        }
        bool anchors = t->isVideo && packetTime(pkt.get()) != AV_NOPTS_VALUE;
        int64_t anchorTs = packetTime(pkt.get());
        pending_.push_back({t, PacketPtr(av_packet_clone(pkt.get()))});
        av_packet_unref(pkt.get());
        if (anchors) {
            resolveCellOffset(anchorTs);
            if (!flushPending()) return false;
        } else if (pending_.size() > kMaxPendingPackets) {
            if (!flushPending()) return false;
        }
    }
    if (ret != AVERROR_EOF) result_.warnings.push_back("Stopped reading early: " + averror(ret));
    if (!flushPending()) return false;
    for (Track& t : tracks_) {
        if (t.held && !write(t, t.held.get())) return false;
        t.held.reset();
        if (t.dec && !finishLpcm(t)) return false;
    }
    if ((ret = av_write_trailer(out_)) < 0) return fail("Could not finish the MKV", ret);
    return true;
}

RemuxResult RemuxJob::run() {
    bool ok = openInput() && createOutput() && remux();
    if (out_ && out_->pb) avio_closep(&out_->pb);

    result_.cancelled = cancelled_;
    if (ok && !cancelled_) {
        std::error_code ec;
        fs::rename(tempPath_, req_.outputPath, ec);
        if (ec) {
            fail("Could not move the finished MKV into place: " + ec.message());
        } else {
            result_.completed = true;
            result_.outputPath = req_.outputPath;
            if (offsetKnown_ && lastVideoEnd_ != AV_NOPTS_VALUE) result_.durationTicks = uint64_t(lastVideoEnd_);
            fraction_ = 1;
        }
    }
    if (!result_.completed && !tempPath_.empty()) {
        std::error_code ec;
        fs::remove(tempPath_, ec);
    }
    if (untimedDropped_ > 0)
        result_.warnings.push_back("Dropped " + std::to_string(untimedDropped_) + " packets that had no timestamp.");
    if (audioRepairs_ > 0)
        result_.warnings.push_back("Repaired " + std::to_string(audioRepairs_) +
                                   " mis-stamped audio frames.");
    if (monotonicFixes_ > 0)
        result_.warnings.push_back("Adjusted " + std::to_string(monotonicFixes_) +
                                   " timestamps to keep tracks in order at cell joins.");
    cleanup();
    return result_;
}

void RemuxJob::cleanup() {
    for (Track& t : tracks_) {
        t.held.reset();
        avcodec_free_context(&t.dec);
        avcodec_free_context(&t.enc);
        if (t.fifo) av_audio_fifo_free(t.fifo);
        t.fifo = nullptr;
    }
    pending_.clear();
    if (out_) {
        if (out_->pb) avio_closep(&out_->pb);
        avformat_free_context(out_);
        out_ = nullptr;
    }
    avformat_close_input(&in_);
}

// MARK: - Public API

RemuxJob* createRemuxJob(const RemuxRequest& request) { return new RemuxJob(request); }
RemuxResult runRemuxJob(RemuxJob* job) { return job->run(); }
RemuxProgress remuxJobProgress(RemuxJob* job) { return job->progress(); }
void cancelRemuxJob(RemuxJob* job) { job->cancel(); }
void destroyRemuxJob(RemuxJob* job) { delete job; }

} // namespace dc
