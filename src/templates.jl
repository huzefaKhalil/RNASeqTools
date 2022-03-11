function prepare_data(data_path::String, genome::Genome; files=FastqgzFiles)
    files = files(data_path)
    println("Preprocessing files:")
    show(files)
    trimmed = trim_fastp(files)
    println("Aligning files...")
    bams = align_mem(trimmed, genome;)
    println("Computing coverage...")
    compute_coverage(bams)
end

#function de_genes(features::Features, coverages::Vector{Coverage}, conditions::Dict{String, UnitRange{Int}}, results_path::String; between_conditions=nothing, add_keys=["BaseValueFrom", "BaseValueTo", "LogFoldChange", "PValue", "AdjustedPValue"])
#    between_conditions = isnothing(between_conditions) ? combinations(collect(conditions), 2) : [((a,conditions[a]), (b,conditions[b])) for (a,b) in between_conditions]
#    for ((name1, range1), (name2, range2)) in between_conditions
#        annotate!(features, coverages[range1], coverages[range2])
#        write(joinpath(results_path, name1 * "_vs_" * name2 * ".csv"), asdataframe(features, add_keys=add_keys))
#    end
#end

function feature_count(features::Features, coverages::Vector{Coverage}, conditions::Dict{String, UnitRange{Int}}, results_path::String; between_conditions=nothing)
    expnames = Dict{String,Vector{String}}()
    for (name, range) in conditions
        annotate!(features, coverages[range]; count_key="$name")
        expnames[name] = ["$name$i" for i in 1:length(range)]
    end
    write(joinpath(results_path, "all_counts.csv"), asdataframe(features; add_keys=vcat([val for val in values(expnames)]...)))
    if !isnothing(between_conditions)
        for (cond1, cond2) in between_conditions
            exps = [expnames[cond1]...,expnames[cond2]...]
            write(joinpath(results_path, "$(cond1)_vs_$cond2.csv"), asdataframe(features; add_keys=exps))
        end
    end
end

function feature_count(features::Features, bams::SingleTypeFiles, conditions::Dict{String, UnitRange{Int}}, results_path::String; between_conditions=nothing, is_reverse_complement=false, only_unique_alignments=true)
    expnames = Dict{String,Vector{String}}()
    mybams = copy(bams)
    for (name, range) in conditions
        mybams = bams[range]
        annotate!(features, mybams; count_key="$name", is_reverse_complement=is_reverse_complement, only_unique_alignments=only_unique_alignments)
        expnames[name] = ["$name$i" for i in 1:length(range)]
        println("Finished counting in $name")
    end
    write(joinpath(results_path, "all_counts.csv"), asdataframe(features; add_keys=vcat([val for val in values(expnames)]...)))
    if !isnothing(between_conditions)
        for (cond1, cond2) in between_conditions
            exps = [expnames[cond1]...,expnames[cond2]...]
            write(joinpath(results_path, "$(cond1)_vs_$cond2.csv"), asdataframe(features; add_keys=exps))
        end
    end
end

function feature_ratio(features::Features, coverage_files::PairedSingleTypeFiles, results_file::String)
    result_string = "filename\t" * join([t for t in features.types], "\t") * "\n"
    split_features = split(features)
    for (file1,file2) in coverage_files
        coverage = Coverage(file1,file2)
        result_string *= basename(file1)[1:end-11] * "\t" * join([covratio(f, coverage) for f in split_features], "\t") * "\n"
    end
    write(results_file, result_string)
end

function unmapped_reads(bams::SingleTypeFiles)
    for bam_file in bams
        record = BAM.Record()
        reader = BAM.Reader(open(bam_file))
        writer = GzipCompressorStream(open(joinpath(dirname(bam_file), "unmapped_" * basename(bam_file)[1:end-3] * "fasta.gz"), "w"))
        while !eof(reader)
            read!(reader, record)
            BAM.ismapped(record) && continue
            write(writer, ">$(BAM.tempname(record))\n$(BAM.sequence(record))\n")
        end
        close(writer)
        close(reader)
    end
end

function remove_features(bams::SingleTypeFiles, features::Features; sam_bin="samtools", is_reverse_complement=false, overwrite_existing=false, remove_unmapped=true, prefix="filtered_")
    outnames = String[]
    for bam_file in bams
        startswith(bam_file, prefix) && continue
        record = BAM.Record()
        reader = BAM.Reader(open(bam_file))
        h = header(reader)
        fname = joinpath(dirname(bam_file), prefix * basename(bam_file))
        push!(outnames, fname)
        !overwrite_existing && isfile(fname) && continue
        writer = BAM.Writer(BGZFStream(open(fname, "w"), "w"), h)
        while !eof(reader)
            read!(reader, record)
            current_read = (isread2(record) != is_reverse_complement) ? :read2 : :read1
            s = (BAM.ispositivestrand(record) != (current_read === :read2)) ? STRAND_POS : STRAND_NEG
            (BAM.ismapped(record) == remove_unmapped) || continue
            BAM.ismapped(record) && hasoverlap(features, Interval(BAM.refname(record), leftposition(record), rightposition(record), s, Annotation())) && continue
            write(writer, record)
        end
        sleep(0.1)
        close(writer)
        close(reader)
        run(`$sam_bin index $fname`)
        run(pipeline(`$sam_bin stats $fname`, stdout=fname * ".log"))
    end
    return SingleTypeFiles(outnames)
end

function transcriptional_startsites(texreps::SingleTypeFiles, notexreps::SingleTypeFiles, results_gff::String)
    tex_coverage = Coverage(texreps)
    notex_coverage = Coverage(notexreps)
    tss_pos = tsss(tex_coverage, notex_coverage)
    tss_features = Features(tss_pos)
    write(results_gff, tss_features)
end

function full_annotation(features::Features, texdict::Dict{String,Coverage}, notexdict::Dict{String,Coverage}, termdict::Dict{String,Coverage}, results_gff::String;
                            cds_type="CDS", five_type="5UTR", three_type="3UTR", igr_type="IGR", min_tex_ratio=1.3, min_step=5, min_background_ratio=1.2, window_size=10)
    @assert keys(texdict) == keys(notexdict)
    tss_pos = Dict(key=>tsss(notexdict[key], texdict[key]; min_tex_ratio=min_tex_ratio, min_step=min_step, min_background_ratio=min_background_ratio, window_size=window_size) for key in keys(texdict))
    term_pos = Dict(key=>terms(termdict[key], min_step=min_step, min_background_ratio=min_background_ratio, window_size=window_size) for key in keys(termdict))
    addutrs!(features; tss_positions=tss_pos, term_positions=term_pos, cds_type=cds_type, five_type=five_type, three_type=three_type)
    addigrs!(features; igr_type=igr_type)
    write(results_gff, features)
end

function tss_annotation(tex_files::PairedSingleTypeFiles, notex_files::PairedSingleTypeFiles, results_gff::String;
                            min_tex_ratio=1.3, min_step=10, window_size=10, min_background_ratio=1.2)
    coverages_tex = merge([Coverage(f1, f2) for (f1, f2) in tex_files])
    coverages_notex = merge([Coverage(f1, f2) for (f1, f2) in notex_files])
    tss = tsss(coverages_notex, coverages_tex; min_tex_ratio=min_tex_ratio, min_step=min_step, window_size=window_size, min_background_ratio=min_background_ratio)
    write(results_gff, Features(tss; type="TSS"))
end

function conserved_features(features::Features, source_genome::Genome, target_genomes::SingleTypeFiles, results_path::String)
    targets = [Genome(genome_file) for genome_file in target_genomes]
    seqs = featureseqs(features, source_genome)
    alignments = align_mem(seqs, targets, joinpath(results_path, "utrs.bam"))
    annotate!(features, alignments)
    write(joinpath(results_path, "features.gff"), features)
end

function chimeric_alignments(features::Features, bams::SingleTypeFiles, results_path::String; conditions::Dict{String, UnitRange{Int}}=Dict("chimeras"=>1:length(bams)),
                            filter_types=["rRNA", "tRNA"], min_distance=1000, priorityze_type="sRNA", overwrite_type="IGR", merge_annotation_types=true,
                            is_reverse_complement=true, only_unique_alignments=true, model=:fisher, min_reads=5, max_fdr=0.05,
                            overwrite_existing=false)

    isdir(joinpath(results_path, "interactions")) || mkpath(joinpath(results_path, "interactions"))
    isdir(joinpath(results_path, "stats")) || mkpath(joinpath(results_path, "stats"))
    isdir(joinpath(results_path, "singles")) || mkpath(joinpath(results_path, "singles"))
    isdir(joinpath(results_path, "graphs")) || mkpath(joinpath(results_path, "graphs"))
    for (condition, r) in conditions
        !overwrite_existing &&
            isfile(joinpath(results_path, "interactions", "$(condition).csv")) &&
            isfile(joinpath(results_path, "singles", "$(condition).csv")) &&
            isfile(joinpath(results_path, "graphs", "$(condition).jld2")) &&
            isfile(joinpath(results_path, "stats", "$(condition).csv")) &&
            continue
        replicate_ids = Vector{Symbol}()
        interactions = Interactions()
        for (i, bam) in enumerate(bams[r])
            replicate_id = Symbol("$(condition)_$i")
            push!(replicate_ids, replicate_id)
            println("Reading $bam")
            alignments = Alignments(bam; only_unique_alignments=only_unique_alignments, is_reverse_complement=is_reverse_complement)
            println("Annotating alignments...")
            annotate!(alignments, features; prioritize_type=priorityze_type, overwrite_type=overwrite_type)
            println("Building graph for replicate $replicate_id...")
            append!(interactions, alignments, replicate_id; min_distance=min_distance, filter_types=filter_types, merge_annotation_types=merge_annotation_types)
            empty!(alignments)
        end
        println("Computing significance levels...")
        addpvalues!(interactions; method=model)
        addrelativepositions!(interactions, features)

        total_reads = sum(interactions.edges[!, :nb_ints])
        above_min_reads = sum(interactions.edges[interactions.edges.nb_ints .>= min_reads, :nb_ints])
        total_ints = nrow(interactions.edges)
        above_min_ints = sum(interactions.edges.nb_ints .>= min_reads)
        total_sig_reads = sum(interactions.edges[interactions.edges.fdr .<= max_fdr, :nb_ints])
        above_min_sig_reads = sum(interactions.edges[(interactions.edges.fdr .<= max_fdr) .& (interactions.edges.nb_ints .>= min_reads), :nb_ints])
        total_sig_ints = sum(interactions.edges.fdr .<= max_fdr)
        above_min_sig_ints = sum((interactions.edges.fdr .<= max_fdr) .& (interactions.edges.nb_ints .>= min_reads))
        println("\n\t\ttotal\treads>=$min_reads\tfdr<=$max_fdr\tboth")
        println("reads:\t\t$total_reads\t$above_min_reads\t\t$total_sig_reads\t\t$above_min_sig_reads")
        println("interactions:\t$total_ints\t$above_min_ints\t\t$total_sig_ints\t\t$above_min_sig_ints\n")
        write(joinpath(results_path, "graphs", "$(condition).jld2"), interactions)
        write(joinpath(results_path, "interactions", "$(condition).csv"), asdataframe(interactions; output=:edges, min_reads=min_reads, max_fdr=max_fdr))
        write(joinpath(results_path, "stats", "$(condition).csv"), asdataframe(interactions; output=:stats, min_reads=min_reads, max_fdr=max_fdr))
        write(joinpath(results_path, "singles", "$(condition).csv"), asdataframe(interactions; output=:nodes, min_reads=min_reads, max_fdr=max_fdr))
    end
    (!overwrite_existing && isfile(joinpath(results_path, "singles.xlsx")) && isfile(joinpath(results_path, "interactions.xlsx"))) && return
    println("Writing tables...")
    singles = CsvFiles(joinpath(results_path, "singles"))
	ints = CsvFiles(joinpath(results_path, "interactions"))
	write(joinpath(results_path, "singles.xlsx"), singles)
	write(joinpath(results_path, "interactions.xlsx"), ints)
end

"""
Pipeline to create krona plots from sequence files and DB.
Creates 4 files:
    *.kraken2_results.txt
    *.report.txt
    *.error.txt
    *.krona.html
"""
function krona_plot_pipeline(
        db_location::String, sequence_file::String;
        threads = 6, report = false
    )
    taxonomy_report = split(sequence_file, ".")[1] * ".report.txt"

    align_kraken2(db_location, sequence_file, threads = threads)
    kronaplot(taxonomy_report)
    # cleanup
    !report && rm(taxonomy_report)
end


"""
DESeq2 pipeline wrapper.
"""
function deseq2_R(
    features::Features,
    bams::SingleTypeFiles,
    conditions::Dict{String, UnitRange{Int}},
    between_conditions::Vector{Tuple{String, String}},
    results_path::String;
    is_reverse_complement=false
)
    all(isfile(joinpath(results_path, cond1 * "_vs_" * cond2 * ".csv")) for (cond1, cond2) in between_conditions) ||
        feature_count(features, bams, conditions,  results_path; between_conditions=between_conditions, is_reverse_complement=is_reverse_complement)

    rcall(:source, joinpath(@__DIR__, "deseq2.R"))
    for (cond1, cond2) in between_conditions
        file = joinpath(results_path, cond1 * "_vs_" * cond2 * ".csv")
        num_ctl, num_exp = length(conditions[cond1]), length(conditions[cond2])
        rcall(:deseq2pipeline, file, num_ctl, num_exp)
    end
end

function direct_rna_pipeline(seqs_file::String, genome_file::String, annotation_file::Union{String, Nothing};
                                minimap2_bin="minimap2", sam_bin="samtools", filter_types=["rRNA"],
                                prefix="filtered_", overwrite_existing=false)
    ending = ""
    occursin(".fasta", seqs_file) && (ending=".fasta")
    occursin(".fastq", seqs_file) && (ending=".fastq")
    endswith(seqs_file, ".gz") && (ending*=".gz")
    ending == ".gz" && throw(AssertionError("Only .fasta, .fastq, .fasta.gz and .fastq.gz allowed!"))
    dir_name = dirname(seqs_file)
    out_file = joinpath(dir_name, basename(seqs_file)[1:end-length(ending)] * ".bam")
    stats_file = out_file * ".log"
    (overwrite_existing || !isfile(out_file)) &&
        run(pipeline(`$minimap2_bin -ax map-ont -k14 --MD -Y $genome_file $seqs_file`, stdout=pipeline(`$sam_bin view -u`, stdout=pipeline(`$sam_bin sort -o $out_file`))))
    (overwrite_existing || !isfile(stats_file)) &&
        run(pipeline(`$sam_bin index $out_file`, `$sam_bin stats $out_file`, stats_file))
    compute_coverage(out_file; overwrite_existing=overwrite_existing)

    if !isnothing(annotation_file) && (!isnothing(filter_types) && length(filter_types) > 0)
        features = Features(annotation_file, filter_types)
        remove_features(SingleTypeFiles([out_file]), features; prefix=prefix, sam_bin=sam_bin, overwrite_existing=overwrite_existing)
        compute_coverage(joinpath(dir_name, prefix * basename(seqs_file)[1:end-length(ending)] * ".bam"); overwrite_existing=overwrite_existing)
    end
end
direct_rna_pipeline(seqs_file::String; minimap2_bin="minimap2", sam_bin="samtools", filter_types=["rRNA"], prefix="filtered_", overwrite_existing=false) =
    direct_rna_pipeline(seqs_file, GENOME_VCH, ANNOTATION_VCH; minimap2_bin=minimap2_bin, sam_bin=sam_bin, filter_types=filter_types, prefix=prefix, overwrite_existing=overwrite_existing)
direct_rna_pipeline(seqs_file::String, genome_file::String; minimap2_bin="minimap2", sam_bin="samtools", overwrite_existing=false) =
    direct_rna_pipeline(seqs_file, genome_file, nothing; minimap2_bin=minimap2_bin, sam_bin=sam_bin, overwrite_existing=overwrite_existing)