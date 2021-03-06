library(TCGAbiolinks)
library(DESeq2)
library(maftools)

library(BiocParallel)
register(MulticoreParam(3))

library(clusterProfiler)
library(enrichplot)
library(pathview)
library(plotly)
library(dplyr)
library("org.Hs.eg.db", character.only = TRUE)

require(grid)
require(png)

prepDE <- function(proj_name, setdiff = T, count_thresh = 10, maf_fn = sprintf("gdcData/MC3/%s.mutSig.maf", proj_name), 
                   counts_fn = sprintf("gdcData/HTseq/%s_counts.rda", proj_name)){
  
  #maf_fn = sprintf("gdcData/MC3-subtyped/%s.mutSig.maf", proj_name)
  #counts_fn = sprintf("gdcData/HTseq/%s_counts.rda", proj_name)

  if(!file.exists(counts_fn)){
  	counts_query <- GDCquery(project = proj_name, 
  	                  data.category = "Transcriptome Profiling", 
  	                  data.type = "Gene Expression Quantification", 
  	                  workflow.type = "HTSeq - Counts")
  	GDCdownload(counts_query)
  	counts <- GDCprepare(query = counts_query, save = TRUE, 
           	         	 save.filename = counts_fn)
  } else {
  	load(counts_fn)
  	counts <- data
  	rm(data)
  }
  
  maf <- read.maf(maf_fn, verbose = F)
  ref_samples <- unique(subsetMaf(maf, genes = c("PIK3CA", "PTEN"))@data$Tumor_Sample_Barcode) 
  mtor_samples <- unique(subsetMaf(maf, genes = "MTOR")@data$Tumor_Sample_Barcode)
  
  # remove samples with co-occuring mutations 
  #REF_samples <- sample(substr(base::setdiff(ref_samples, mtor_samples),1,16), 2*length(mtor_samples))
  REF_samples <- substr(base::setdiff(ref_samples, mtor_samples),1,16)
  if(setdiff == T){
    MTOR_samples <- substr(base::setdiff(mtor_samples, ref_samples),1,16)
  } else {MTOR_samples <- substr(mtor_samples,1,16)}
  
  # reduce counts to tumours of interest
  counts <- subset(counts, select = (substr(counts$barcode,1,16) %in% union(MTOR_samples, REF_samples)) )
  
  # annotate mtor mutants
  colData(counts)$mtor_mut <- substr(counts$barcode,1,16) %in% MTOR_samples
  
  # reduce to credible reads, and perform DEA
  dds <- DESeqDataSet(counts, design = ~ mtor_mut)
  sel <- rowSums(counts(dds)) >= count_thresh
  dds <- DESeq(dds[sel,], parallel = T)
  res <- results(dds)

  # return maf restricted to ref & mtr samples
  r_maf <- subsetMaf(maf, tsb = union(ref_samples, mtor_samples))

  return(list(maf = r_maf, dds = dds, res = res, counts = counts))
}

# from https://stackoverflow.com/questions/60141841/how-to-get-pathview-plot-displayed-directly-rather-than-saving-as-a-file-in-r
see_pathview <- function(..., save_image = FALSE)
{
  msg <- capture.output(pathview::pathview(...), type = "message")
  msg <- grep("image file", msg, value = T)
  filename <- sapply(strsplit(msg, " "), function(x) x[length(x)])
  img <- png::readPNG(filename)
  grid::grid.raster(img)
  if(!save_image) invisible(file.remove(filename))
}


kegg_highlight <- function(counts, res, pth = "hsa04151"){
  # from https://learn.gencore.bio.nyu.edu/rna-seq-analysis/gene-set-enrichment-analysis/
  # map via HGNC alias, for higher fidelity than ENSG id
  gene_list <- res$log2FoldChange
  names(gene_list) <- rowData(counts)$external_gene_name[match(rownames(res), rowData(counts)$ensembl_gene_id)]
  gene_list <- sort(gene_list, decreasing = T)
  gene_list <- gene_list[!duplicated(names(gene_list))]
  #goe <- gseGO(geneList=gene_list, 
  #             ont ="ALL", 
  #             keyType = "ALIAS", 
  #             #nPerm = 10000, 
  #             minGSSize = 3, 
  #             maxGSSize = 800, 
  #             pvalueCutoff = 0.05, 
  #             verbose = TRUE, 
  #             OrgDb = org.Hs.eg.db, 
  #             pAdjustMethod = "none")
  
  
  # Convert gene IDs for gseKEGG function
  # We will lose some genes here because not all IDs will be converted.
  # Mostly these are linkRNA and pseudogenes. Possibly some splice variants, but will keep the more significant of each. 
  gene_tr <- bitr(names(gene_list), fromType = "ALIAS", toType = "ENTREZID", OrgDb=org.Hs.eg.db)
  gene_tr <- gene_tr[!duplicated(gene_tr$ALIAS),]
  
  names(gene_list) <- gene_tr$ENTREZID[match(names(gene_list), gene_tr$ALIAS)]
  gene_list <- gene_list[!is.na(names(gene_list)) & !duplicated(names(gene_list))]
  
  kpe <- gseKEGG(geneList     = gene_list,
                 organism     = "hsa",
                 #nPerm        = 10000,
                 minGSSize    = 3,
                 maxGSSize    = 800,
                 pvalueCutoff = 0.05,
                 pAdjustMethod = "none",
                 keyType       = "ncbi-geneid")
  
  
  see_pathview(gene.data=gene_list, pathway.id=pth, species = "hsa", low = "blue", high = "red")

}

# from https://stackoverflow.com/questions/34093169/horizontal-vertical-line-in-plotly
gg_hline <- function(y = 0, color = "blue") {
  list(
    type = "line", 
    x0 = 0, 
    x1 = 1, 
    xref = "paper",
    y0 = y, 
    y1 = y, 
    line = list(color = color)
  )
}

volcano <- function(dds, res, contrast, goi = 'mTOR'){

  # dds and res should have exactly the same rows
  goi_sel <- rowData(dds)$external_gene_name %in% goi

  vasc_genes <- c('UHRF1', 'MKI67', 'VEGFA', 'ANGPT2', 'CH25H', 'PIEZO2', 'SERPINE1',
                  'SERPINA3', 'LAD1', 'APLN', 'S100A11', 'HIF1A', 'CDH5', 
                  'ADGRL4', 'CLEC14A', 'LDB2', 'ECSCR', 'MYCT1', 'RHOJ', 'VWF', 
                  'TIE1', 'KDR', 'ESAM', 'CD93', 'PTPRB', 'ADGRF5', 'SPARCL1', 
                  'EMCN', 'ROBO4', 'ENG', 'TEK', 'S1PR1', 'A2M', 'JAM2', 'MEF2C', 
                  'COL15A1', 'PECAM1', 'CALCRL', 'CLEC3B', 'PLVAP', 'RGS5', 'LRRC32', 
                  'EBF1', 'ADCY4', 'ACVRL1', 'ADGRA2', 'APLNR', 'TM4SF18', 'GNG11', 
                  'CNRIP1', 'ZNF423', 'GIMAP8', 'PDGFD', 'ITGA9', 'EDNRB')

  vasc_sel <- rowData(dds)$external_gene_name %in% vasc_genes

  p <- as.data.frame(res) %>%
       mutate(gcol = 'Other gene') %>%
       mutate(gcol = replace(gcol, goi_sel, 'Gene of interest')) %>%
       mutate(gcol = replace(gcol, vasc_sel, 'Gene in vascularization signature')) %>%
       mutate(gcol = replace(gcol, rowData(dds)$external_gene_name == 'MTOR', 'MTOR')) %>%
       mutate(padj = replace(padj, (abs(log2FoldChange) > 8), NA)) %>%
       plot_ly(x = ~log2FoldChange, y = ~ -log10(padj),
               type = 'scatter', mode = 'markers', 
               text = rowData(dds)$external_gene_name, color = ~gcol) %>% 
       layout(title = contrast, shapes = list(gg_hline(-log10(0.01)), gg_hline(-log10(0.05))) ) 

  p


} 
