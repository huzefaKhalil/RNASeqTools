function write_file(filename::String, content::String)
    open(filename, "w") do f
        write(f, content)
    end
end

struct AlignmentPart
    refstart::Int
    refstop::Int
    readstart::Int
    readstop::Int
    isprimary::Bool
    chr::String
    tag::Union{String, Nothing}
end

function AlignmentPart(xa_part::String)
    chr, pos, cigar, nm = split(xa_part, ",")
    refstart = parse(Int, pos)
    readstart, readstop, relrefstop = positions(cigar)
    return AlignmentPart(refstart, refstart+relrefstop, readstart, readstop, false, chr, nothing)
end

struct ReadAlignment
    parts::Vector{AlignmentPart}
    alt::Vector{Vector{AlignmentPart}}
end

function ReadAlignment(record::BAM.Record)
    BAM.ismapped(record) || return ReadAlignment([], [])
    readstart, readstop, relrefstop = positions(BAM.cigar(record))
    aln_part = AlignmentPart(BAM.leftposition(record), BAM.rightposition(record), readstart, readstop, BAM.isprimary(record), BAM.refname(record), nothing)
    alts = hasxatag(record) ? [AlignmentPart(xa) for xa in split(String(xatag(record)))[1:end-1]] : AlignmentPart[]
    return ReadAlignment([aln_part], alts)
end 

Base.iterate(readalignment::ReadAlignment) = Base.iterate(readalignment.parts)
Base.iterate(readalignment::ReadAlignment, state::Int) = Base.iterate(readalignment.parts, state)


function Base.push!(readalignment::ReadAlignment, record::BAM.Record)
    BAM.ismapped(record) || return nothing
    readstart, readstop, relrefstop = positions(BAM.cigar(record))
    push!(readalignment.parts, AlignmentPart(BAM.leftposition(record), BAM.rightposition(record), readstart, readstop, BAM.isprimary(record), BAM.refname(record), nothing))
    hasxatag(record) && push!(readalignment.alt, [AlignmentPart(xa) for xa in split(String(xatag(record)))[1:end-1]])
end

function primaryalignmentpart(readalignment::ReadAlignment)
    for aln_part in readalignment
        aln_part.isprimary && (return aln_part)
    end
end

Base.isempty(readalignment::ReadAlignment) = Base.isempty(readalignment.parts)

struct Alignments <: AlignmentContainer
    dict::Dict{String, ReadAlignment}
    name::Union{String,Nothing}
end

Base.length(alignments::Alignments) = Base.length(alignments.dict)
Base.keys(alignments::Alignments) = Base.keys(alignments.dict)
Base.values(alignments::Alignments) = Base.values(alignments.dict)
function Base.iterate(alignments::Alignments) 
    dictiteration = Base.iterate(alignments.dict)
    isnothing(dictiteration) && (return nothing)
    ((key, aln), state) = dictiteration
    return (aln, state)
end
function Base.iterate(alignments::Alignments, state::Int) 
    dictiteration = Base.iterate(alignments.dict, state)
    isnothing(dictiteration) && (return nothing)
    ((key, aln), state) = dictiteration
    return (aln, state)
end

function Alignments(bam_file::String; stop_at=nothing, name=nothing)
    alignments1, alignments2 = read_bam(bam_file; stop_at=stop_at)
    @assert isempty(alignments2)
    Alignments(alignments1, name)
end

struct PairedAlignments <: AlignmentContainer
    dict::Dict{String, Tuple{ReadAlignment, ReadAlignment}}
    name::Union{String, Nothing}
end

Base.length(alignments::PairedAlignments) = Base.length(alignments.dict)
Base.keys(alignments::PairedAlignments) = Base.keys(alignments.dict)
Base.values(alignments::PairedAlignments) = Base.values(alignments.dict)
function Base.iterate(alignments::PairedAlignments) 
    dictiteration = Base.iterate(alignments.dict)
    isnothing(dictiteration) && (return nothing)
    ((key, (aln1, aln2)), state) = dictiteration
    return ((aln1, aln2), state)
end
function Base.iterate(alignments::PairedAlignments, state::Int) 
    dictiteration = Base.iterate(alignments.dict, state)
    isnothing(dictiteration) && (return nothing)
    ((key, (aln1, aln2)), state) = dictiteration
    return ((aln1, aln2), state)
end

function PairedAlignments(bam_file1::String, bam_file2::String; stop_at=nothing, name=nothing)
    alignments1, alignments_e1 = read_bam(bam_file1; stop_at=stop_at)
    alignments2, alignments_e2 = read_bam(bam_file2; stop_at=stop_at)
    @assert isempty(alignments_e1) && isempty(alignments_e2)
    alignments = Dict(key=>(alignments1[key], alignments2[key]) for key in intersect(Set(keys(alignments1)), Set(keys(alignments2))))
    PairedAlignments(alignments, name)
end

function PairedAlignments(pebam_file::String; stop_at=nothing, name=nothing)
    alignments1, alignments2 = read_bam(pebam_file; stop_at=stop_at)
    alignments = Dict(key=>(alignments1[key], alignments2[key]) for key in intersect(Set(keys(alignments1)), Set(keys(alignments2))))
    PairedAlignments(alignments, name)
end

function read_bam(bam_file::String; stop_at=nothing)
    record = BAM.Record()
    reader = BAM.Reader(open(bam_file), index=bam_file*".bai")
    reads1 = Dict{String, ReadAlignment}()
    reads2 = Dict{String, ReadAlignment}()
    c = 0
    while !eof(reader)
        read!(reader, record)
        id = BAM.tempname(record)
        current_read_dict = isread2(record) && ispaired(record) ? reads2 : reads1
        id in keys(current_read_dict) ? push!(current_read_dict[id], copy(record)) : push!(current_read_dict, id=>ReadAlignment(copy(record)))
        c += 1
        isnothing(stop_at) || ((c >= stop_at) && break) 
    end
    close(reader)
    return reads1, reads2
end

struct Genome <: SequenceContainer
    seq::LongDNASeq
    chrs::Dict{String, UnitRange{Int}}
    name::Union{String, Nothing}
end

function Genome(genome_fasta::String)
    (name, sequences) = read_genomic_fasta(genome_fasta)
    chrs::Dict{String,UnitRange{Int}} = Dict()
    total_seq = ""
    temp_start = 1
    for (chr, chr_seq) in sequences
        chrs[chr] = temp_start:(temp_start+length(chr_seq)-1)
        temp_start += length(chr_seq)
        total_seq *= chr_seq
    end
    Genome(LongDNASeq(total_seq), chrs, name)
end

function Base.iterate(genome::Genome)
    (chr, slice) = first(genome.chrs)
    ((chr, genome.seq[slice]), 1)
end

function Base.iterate(genome::Genome, state::Int)
    state += 1
    state > genome.chrs.count && (return nothing)
    for (i, (chr, slice)) in enumerate(genome.chrs)
        (i == state) && (return ((chr, genome.seq[slice]), state))
    end
end

function Base.write(file::String, genome::Genome)
    write_genomic_fasta(Dict(chr=>String(seq) for (chr, seq) in genome), file; name=genome.name)
end

function read_genomic_fasta(fasta_file::String)
    genome::Dict{String, String} = Dict()
    chrs = String[]
    start_ids = Int[]
    name = ""
    open(fasta_file, "r") do file
        lines = readlines(file)
        startswith(lines[1], ">") && (name = join(split(lines[1])[2:end]))
        for (i,line) in enumerate(lines)
            startswith(line, ">") &&  (push!(chrs, split(line," ")[1][2:end]); push!(start_ids, i))
        end
        push!(start_ids, length(lines)+1)
        for (chr, (from,to)) in zip(chrs, [@view(start_ids[i:i+1]) for i in 1:length(start_ids)-1])
            genome[chr] = join(lines[from+1:to-1])
        end
    end
    return name, genome
end

function write_genomic_fasta(genome::Dict{String, String}, fasta_file::String; name=nothing, chars_per_row=80)
    open(fasta_file, "w") do file
        for (i, (chr, seq)) in enumerate(genome)
            s = String(seq)
            l = length(s)
            !isnothing(name) ? println(file, ">$chr") : println(file, ">$chr $name")
            for i in 0:length(seq)÷chars_per_row
                ((i+1)*chars_per_row > l) ? println(file, s[i*chars_per_row+1:end]) : println(file, s[i*chars_per_row+1:(i+1)*chars_per_row])
            end
        end
    end
end

struct PairedReads <: SequenceContainer
    dict::Dict{String, LongDNASeqPair}
    name::Union{String, Nothing}
end

Base.length(reads::PairedReads) = Base.length(reads.dict)
Base.keys(reads::PairedReads) = Base.keys(reads.dict)
Base.values(reads::PairedReads) = Base.values(reads.dict)
function Base.iterate(reads::PairedReads) 
    ((key, (read1, read2)), state) = Base.iterate(reads.dict)
    return ((read1, read2), state)
end
function Base.iterate(reads::PairedReads, state::Int) 
    ((key, (read1, read2)), state) = Base.iterate(reads.dict, state)
    return ((read1, read2), state)
end

function PairedReads(file1::String, file2::String; description=nothing, stop_at=nothing)
    reads1 = read_reads(file1; nb_reads=stop_at)
    reads2 = read_reads(file2; nb_reads=stop_at)
    @assert length(reads1) == length(reads2)
    @assert all([haskey(reads2, key) for key in keys(reads1)])
    PairedReads(Dict(key=>(reads1[key], reads2[key]) for key in keys(reads1)), description)
end

function Base.write(fasta_file1::String, fasta_file2::String, reads::PairedReads)
    f1 = endswith(fasta_file1, ".gz") ? GzipCompressorStream(open(fasta_file1, "w")) : open(fasta_file1, "w")
    f2 = endswith(fasta_file2, ".gz") ? GzipCompressorStream(open(fasta_file2, "w")) : open(fasta_file2, "w")
    for (key, (read1, read2)) in reads.dict
        write(f1, ">$key\n$(String(read1))\n")
        write(f2, ">$key\n$(String(read2))\n")
    end
    close(f1)
    close(f2)
end

struct Reads <: SequenceContainer
    dict::Dict{String, LongDNASeq}
    name::Union{String, Nothing}
end

Base.length(reads::Reads) = Base.length(reads.dict)
Base.keys(reads::Reads) = Base.keys(reads.dict)
Base.values(reads::Reads) = Base.values(reads.dict)
function Base.iterate(reads::Reads) 
    ((key, read), state) = Base.iterate(reads.dict)
    return (read, state)
end
function Base.iterate(reads::Reads, state::Int) 
    ((key, (read1, read2)), state) = Base.iterate(reads.dict, state)
    return (read, state)
end

function Base.write(fasta_file::String, reads::Reads)
    f = endswith(fasta_file, ".gz") ? GzipCompressorStream(open(fasta_file, "w")) : open(fasta_file, "w")
    for (key, read) in reads.dict
        write(f, ">$key\n$(String(read))\n")
    end
    close(f)
end

function Reads(file::String; description="", stop_at=nothing)
    reads = read_reads(file, nb_reads=stop_at)
    Reads(reads, description)
end

function Reads(f, paired_reads::PairedReads; use_when_tied=:none)
    @assert use_when_tied in [:none, :read1, :read2]
    reads = Dict{UInt, LongDNASeq}()
    for (key, (read1, read2)) in paired_reads
        if use_when_tied == :read1 
            f(read1) ? push!(reads, key=>copy(read1)) : (f(read2) && push!(reads, key=>copy(read2)))
        elseif use_when_tied == :read2
            f(read2) ? push!(reads, key=>copy(read2)) : (f(read1) && push!(reads, key=>copy(read1)))
        elseif use_when_tied == :none
            check1, check2 = f(read1), f(read2)
            check1 && check2 && continue
            check1 && push!(reads, key=>copy(read1))
            check2 && push!(reads, key=>copy(read2))
        end
    end
    Reads(reads, paired_reads.name)
end

function read_reads(file::String; nb_reads=nothing)
    @assert any([endswith(file, ending) for ending in [".fastq", ".fastq.gz", ".fasta", ".fasta.gz"]])
    reads::Dict{String, LongDNASeq} = Dict()
    is_fastq = any([endswith(file, ending) for ending in [".fastq", ".fastq.gz"]])
    is_zipped = endswith(file, ".gz")
    f = is_zipped ? GzipDecompressorStream(open(file, "r")) : open(file, "r")
    reader = is_fastq ? FASTQ.Reader(f) : FASTA.Reader(f)
    record = is_fastq ? FASTQ.Record() : FASTA.Record()
    sequencer = is_fastq ? FASTQ.sequence : FASTA.sequence
    read_counter = 0
    while !eof(reader)
        read!(reader, record)
        push!(reads, identifier(record) => LongDNASeq(sequencer(record)))
        read_counter += 1
        isnothing(nb_reads) || (read_counter >= nb_reads && break)
    end
    close(reader)
    return reads
end

struct SingleTypeFiles <: FileCollection
    list::Vector{String}
    type::String
end

function SingleTypeFiles(files::Vector{String})
    endings = [fname[findlast(fname, "."):end] for fname in files]
    @assert length(unique(endings)) == 1
    SingleTypeFiles(files, endings[1])
end

function SingleTypeFiles(folder::String, type::String)
    SingleTypeFiles([joinpath(folder, fname) for fname in readdir(folder) if endswith(fname, type)], type)
end

function SingleTypeFiles(folder::String, type::String, prefix::String)
    SingleTypeFiles([joinpath(folder, fname) for fname in readdir(folder) if (endswith(fname, type) && startswith(fname, prefix))], type)
end

function Base.iterate(files::SingleTypeFiles)
    isempty(files.list) && (return nothing)
    return (files.list[1], 1)
end

function Base.iterate(files::SingleTypeFiles, state::Int)
    state + 1 > length(files.list) && (return nothing)
    return (files.list[state+1], state + 1)
end

function hassingledir(files::SingleTypeFiles)
    return length(unique(dirname(file) for file in files)) == 1
end

function Base.dirname(files::SingleTypeFiles)
    @assert hassingledir(files)
    return dirname(files.list[1])
end

struct PairedSingleTypeFiles <: FileCollection
    list::Vector{Tuple{String,String}}
    type::String
    suffix1::Union{String,Nothing}
    suffix2::Union{String,Nothing}
end

function PairedSingleTypeFiles(files1::Vector{String}, files2::Vector{String})
    endingsa = [fname[findlast(fname, "."):end] for fname in files1]
    endingsb = [fname[findlast(fname, "."):end] for fname in files2]
    @assert (length(unique(endingsa)) == 1) && (unique(endingsa) == unique(endingsb))
    PairedSingleTypeFiles(collect(zip(files1, files2)), endingsa[1], nothing, nothing)
end

function PairedSingleTypeFiles(folder::String, type::String; suffix1="_1", suffix2="_2", prefix=nothing)
    type_files = [joinpath(folder, fname) for fname in readdir(folder) if isnothing(prefix) ? endswith(fname, type) : endswith(fname, type) && startswith(fname, prefix)]
    names1 = [f[1:end-(length(type)+length(suffix1))] for f in type_files if f[end-(length(type)+length(suffix1)-1):end-length(type)] == suffix1]
    names2 = [f[1:end-(length(type)+length(suffix2))] for f in type_files if f[end-(length(type)+length(suffix2)-1):end-length(type)] == suffix2]
    @assert Set(names1) == Set(names2)
    PairedSingleTypeFiles([(joinpath(folder, name * suffix1 * type), joinpath(folder, name * suffix2 * type)) for name in names1], type, suffix1, suffix2)
end

function Base.iterate(files::PairedSingleTypeFiles)
    isempty(files.list) && (return nothing)
    return (files.list[1], 1)
end

function Base.iterate(files::PairedSingleTypeFiles, state::Int)
    state + 1 > length(files.list) && (return nothing)
    return (files.list[state+1], state + 1)
end

function hassingledir(files::PairedSingleTypeFiles)
    dirs1 = unique([dirname(file[1]) for file in files])
    dirs2 = unique([dirname(file[2]) for file in files])
    return length(dirs1) == 1 && Set(dirs1) == Set(dirs2)
end

function Base.dirname(files::PairedSingleTypeFiles)
    @assert hassingledir(files)
    return dirname(files.list[1][1])
end