#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdlib.h>
#include <stdint.h>

#define asm __asm__

#define read_csr(reg) ({ unsigned long __tmp; \
		asm volatile ("csrr %0, " #reg : "=r"(__tmp)); \
		__tmp; })

#define PAGE_SIZE 4096

void page_stride(uint32_t size, uint64_t runs); 
void random_fetch(uint64_t size, uint64_t runs);

int main(int argc, char *argv[]) {
	
	if (argc != 2)
	{
		printf("Usage: ./tlbstress RUNS\n");
		exit(-1);
	}
	
	uint64_t runs = atoi(argv[1]);
	if (runs <= 0 ) 
	{
		printf("Usage: ./tlbstress RUNS \n");
		exit(-1);
		
	}

	page_stride(512, runs);

	// for (int i = 16; i <= 512; i *= 2)
	// {	
	// 	page_stride(i, runs);
	// 	// random_fetch(i, runs);
	// }

	return 0;
}

void page_stride(uint32_t size, uint64_t runs) {
	
	char *pages;
	uint64_t cycles,
		 dtlb_misses,
		 itlb_misses,
		 l2_tlb_misses;
	pages = malloc(size*PAGE_SIZE*sizeof(char));

	if (pages == NULL) {
		printf("Malloc failed\n");
		exit(-1);
	}	

	for ( uint64_t i = 0; i < PAGE_SIZE*size; i += PAGE_SIZE )
		pages[i % (size * PAGE_SIZE)] = i % 3;


	cycles = read_csr(cycle);
	dtlb_misses = read_csr(0xc06);
	itlb_misses = read_csr(0xc05);
	l2_tlb_misses = read_csr(0xc07);
	
	for (uint64_t i = 0; i < runs*PAGE_SIZE ; i += PAGE_SIZE) {
		pages[i % (size * PAGE_SIZE)] = 1;
	}

	cycles = read_csr(cycle) - cycles;
	dtlb_misses = read_csr(0xc06) - dtlb_misses;
	itlb_misses = read_csr(0xc05) - itlb_misses;
	l2_tlb_misses = read_csr(0xc07) - l2_tlb_misses;

	// printf("\nPage sweep | %u pages, %lu runs\n\n", size, runs);
	// printf("------------------------\n");
	printf("DTLB Misses     = %lu\n", dtlb_misses);
	printf("ITLB Misses     = %lu\n", itlb_misses);
	printf("L2 TLB Misses   = %lu\n", l2_tlb_misses);
	printf("Total cycles    = %lu\n", cycles);
	// printf("------------------------\n");
	
	free(pages);
}

void random_fetch(uint64_t size, uint64_t runs) {
	
	uint64_t j,
		 cycles,
		 dtlb_misses,
		 itlb_misses,
		 l2_tlb_misses;
	
	char *pages;
	pages = malloc(size*PAGE_SIZE*sizeof(char));
	if (pages == NULL) {
		printf("Malloc failed\n");
		exit(-1);
	}

	cycles = read_csr(cycle);
	dtlb_misses = read_csr(0xc06);
	itlb_misses = read_csr(0xc05);
	l2_tlb_misses = read_csr(0xc07);

	for(uint32_t i = 0; i <= runs; i++) {
		j = rand() % PAGE_SIZE*size;
		pages[j % (size * PAGE_SIZE)] = j % 2;
	}
	
	cycles = read_csr(cycle) - cycles;
	dtlb_misses = read_csr(0xc06) - dtlb_misses;
	itlb_misses = read_csr(0xc05) - itlb_misses;
	l2_tlb_misses = read_csr(0xc07) - l2_tlb_misses;


	printf("\nRandom fetch | %lu pages, %lu runs\n\n", size, runs);
	printf("------------------------\n");
	printf("DTLB Misses     = %lu\n", dtlb_misses);
	printf("ITLB Misses     = %lu\n", itlb_misses);
	printf("L2 TLB Misses   = %lu\n", l2_tlb_misses);
	printf("Total cycles    = %lu\n", cycles);
	printf("------------------------\n");
	
	free(pages);

}